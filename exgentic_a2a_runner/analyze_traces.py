#!/usr/bin/env python3
"""Analyze Phoenix agent traces from JSON input.

Reads the raw GraphQL response (JSON) from stdin or a file,
extracts Agent.Session spans and their child spans,
and prints a grouped timing report.

Usage:
    echo "$JSON" | python3 analyze_traces.py
    python3 analyze_traces.py traces.json
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class TraceRecord:
    """Aggregated data for a single Agent.Session trace."""

    session_id: str
    agent_name: str
    benchmark_name: str
    model: str
    num_parallel: int
    status: str
    total_latency_s: float
    experiment_name: str = "default"
    start_time: str = ""
    evaluation_result: bool | None = None

    # Timing from child spans (seconds)
    session_creation_s: float = 0.0
    agent_call_s: float = 0.0
    evaluation_s: float = 0.0
    llm_total_s: float = 0.0
    llm_after_obs_s: float = 0.0
    tool_total_s: float = 0.0
    time_to_first_obs_s: float = 0.0
    overhead_s: float = 0.0
    llm_count: int = 0
    llm_count_after_obs: int = 0
    tool_count: int = 0
    llm_input_tokens: int = 0
    llm_output_tokens: int = 0

    # Infrastructure metrics per pod
    mcp_cpu_utilization_pct: float = 0.0
    mcp_throttle_pct: float = 0.0
    mcp_memory_max_mb: float = 0.0
    mcp_memory_utilization_pct: float = 0.0
    mcp_network_rx_mb: float = 0.0
    mcp_network_tx_mb: float = 0.0
    a2a_cpu_utilization_pct: float = 0.0
    a2a_throttle_pct: float = 0.0
    a2a_memory_max_mb: float = 0.0
    a2a_memory_utilization_pct: float = 0.0
    a2a_network_rx_mb: float = 0.0
    a2a_network_tx_mb: float = 0.0
    has_infra: bool = False


def parse_attrs(node: dict) -> dict:
    """Parse span attributes, handling JSON string or dict."""
    attrs = node.get("attributes", {})
    if isinstance(attrs, str):
        try:
            return json.loads(attrs)
        except (json.JSONDecodeError, TypeError):
            return {}
    return attrs


def parse_traces(data: dict) -> list[TraceRecord]:
    """Parse the full traces response into TraceRecords."""
    traces_data = data.get("traces", [])
    records = []

    for trace in traces_data:
        spans = trace.get("spans", [])
        if not spans:
            continue

        # Find the Agent.Session root span
        root = None
        children = []
        for s in spans:
            if s.get("name") == "Agent.Session":
                root = s
            else:
                children.append(s)

        if root is None:
            continue

        root_attrs = parse_attrs(root)
        meta = root_attrs.get("metadata", {})
        meta_data = root_attrs.get("meta_data", {})

        # Extract grouping fields
        agent_name = meta.get("agent_name", "unknown")
        benchmark_name = meta.get("benchmark_name", "unknown")
        experiment_name = meta.get("experiment_name", "default")
        num_parallel = int(meta.get("num_parallel_tasks", 0))
        session_id = meta.get("session_id", "unknown")
        status = root.get("statusCode", "UNSET")
        evaluation_result = meta.get("evaluation_result")

        # Model from the invoke_agent child span or root metadata
        model = "unknown"
        for s in children:
            if s.get("name", "").startswith("invoke_agent"):
                child_attrs = parse_attrs(s)
                model = (
                    child_attrs.get("gen_ai", {}).get("request", {}).get("model")
                    or child_attrs.get("llm", {}).get("model_name")
                    or "unknown"
                )
                break

        record = TraceRecord(
            session_id=session_id,
            agent_name=agent_name,
            benchmark_name=benchmark_name,
            model=model,
            num_parallel=num_parallel,
            status=status,
            total_latency_s=(root.get("latencyMs") or 0) / 1000.0,
            experiment_name=experiment_name,
            start_time=root.get("startTime", ""),
            evaluation_result=evaluation_result,
        )

        # Extract timing from child spans — collect chat spans separately
        # so we can split them into before/after initial_observation
        invoke_start = None
        invoke_span_id = None
        initial_obs_start = None
        chat_spans = []  # list of (start_time_str, latency_s, span_node)

        root_span_id = root.get("context", {}).get("spanId")

        # First pass: find invoke_agent span ID and runner-level spans
        for s in children:
            name = s.get("name", "")
            latency_s = (s.get("latencyMs") or 0) / 1000.0

            if name == "MCP.CreateSession":
                record.session_creation_s = latency_s
            elif name == "Agent.Call":
                record.agent_call_s = latency_s
            elif name == "Evaluator.Evaluate":
                record.evaluation_s = latency_s
            elif name.startswith("invoke_agent"):
                invoke_start = s.get("startTime")
                invoke_span_id = s.get("context", {}).get("spanId")

        # Second pass: only count chat/tool spans that are children of invoke_agent
        for s in children:
            name = s.get("name", "")
            latency_s = (s.get("latencyMs") or 0) / 1000.0
            parent_id = s.get("parentId")

            # Only process spans parented to invoke_agent
            if parent_id != invoke_span_id:
                continue

            if name.startswith("chat "):
                chat_spans.append((s.get("startTime", ""), latency_s, s))
            elif name == "execute_tool initial_observation":
                initial_obs_start = s.get("startTime")
            elif name.startswith("execute_tool "):
                record.tool_total_s += latency_s
                record.tool_count += 1

        # Process chat spans — split into before/after initial observation
        t_obs = None
        if initial_obs_start:
            try:
                t_obs = datetime.fromisoformat(initial_obs_start.replace("Z", "+00:00"))
            except (ValueError, TypeError):
                pass

        for chat_start_str, chat_latency, chat_span in chat_spans:
            record.llm_total_s += chat_latency
            record.llm_count += 1
            child_attrs = parse_attrs(chat_span)
            token_count = child_attrs.get("llm", {}).get("token_count", {})
            record.llm_input_tokens += int(token_count.get("prompt", 0) or 0)
            record.llm_output_tokens += int(token_count.get("completion", 0) or 0)

            # Classify as before or after initial observation
            is_after_obs = False
            if t_obs and chat_start_str:
                try:
                    t_chat = datetime.fromisoformat(chat_start_str.replace("Z", "+00:00"))
                    if t_chat >= t_obs:
                        record.llm_after_obs_s += chat_latency
                        is_after_obs = True
                except (ValueError, TypeError):
                    record.llm_after_obs_s += chat_latency
                    is_after_obs = True
            else:
                # No initial_observation — count all as "after"
                record.llm_after_obs_s += chat_latency
                is_after_obs = True
            
            if is_after_obs:
                record.llm_count_after_obs += 1

        # Time to first observation: invoke_agent start → initial_observation start
        if invoke_start and initial_obs_start:
            try:
                t_invoke = datetime.fromisoformat(invoke_start.replace("Z", "+00:00"))
                t_obs_dt = datetime.fromisoformat(initial_obs_start.replace("Z", "+00:00"))
                record.time_to_first_obs_s = max((t_obs_dt - t_invoke).total_seconds(), 0.0)
            except (ValueError, TypeError):
                pass

        # Overhead = agent time not accounted for by TTFO + LLM (after obs) + tools
        if record.agent_call_s > 0:
            record.overhead_s = max(
                record.agent_call_s - record.time_to_first_obs_s - record.llm_after_obs_s - record.tool_total_s,
                0.0,
            )

        # Fall back to metadata durations if child spans not found
        if record.agent_call_s == 0:
            record.agent_call_s = float(meta_data.get("agent_call_duration_seconds", 0))
        if record.evaluation_s == 0:
            record.evaluation_s = float(meta.get("evaluation_duration_seconds", 0))

        # Parse infrastructure metrics from root span attributes
        infra = root_attrs.get("infra", {})
        for pod_key in ("mcp", "a2a"):
            pod_infra = infra.get(pod_key, {})
            if pod_infra:
                record.has_infra = True
                setattr(record, f"{pod_key}_cpu_utilization_pct", float(pod_infra.get("cpu_utilization_pct", 0)))
                setattr(record, f"{pod_key}_throttle_pct", float(pod_infra.get("throttle_pct", 0)))
                setattr(record, f"{pod_key}_memory_max_mb", float(pod_infra.get("memory_max_mb", 0)))
                setattr(record, f"{pod_key}_memory_utilization_pct", float(pod_infra.get("memory_utilization_pct", 0)))
                setattr(record, f"{pod_key}_network_rx_mb", float(pod_infra.get("network_rx_mb", 0)))
                setattr(record, f"{pod_key}_network_tx_mb", float(pod_infra.get("network_tx_mb", 0)))

        records.append(record)

    return records


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = min(int(len(s) * p), len(s) - 1)
    return s[idx]


def avg(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def std(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    m = avg(values)
    return (sum((x - m) ** 2 for x in values) / (len(values) - 1)) ** 0.5


def format_time(iso: str) -> str:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except (ValueError, AttributeError):
        return iso[:19].replace("T", " ") if iso else ""


def print_report(records: list[TraceRecord]) -> None:
    if not records:
        print("No Agent.Session traces found.")
        return

    # Group by (experiment_name, agent_name, benchmark_name, model, num_parallel)
    groups: dict[tuple, list[TraceRecord]] = defaultdict(list)
    for r in records:
        key = (r.experiment_name, r.agent_name, r.benchmark_name, r.model, r.num_parallel)
        groups[key].append(r)

    for key, traces in sorted(groups.items()):
        experiment, agent, benchmark, model, num_parallel = key
        n = len(traces)
        errors = sum(1 for t in traces if t.status == "ERROR")
        eval_success = sum(1 for t in traces if t.evaluation_result is True)

        print("=" * 100)
        print(f"Experiment: {experiment}  |  Agent: {agent}  |  Benchmark: {benchmark}  |  Model: {model}  |  Parallel: {num_parallel}")
        print("=" * 100)
        print()

        # Counts
        print(f"  Traces:              {n}")
        print(f"  Errors:              {errors}")
        print(f"  Eval Success:        {eval_success}/{n} ({eval_success / n * 100:.0f}%)")
        print()

        # Timing breakdown
        creation_times = [t.session_creation_s for t in traces]
        agent_times = [t.agent_call_s for t in traces]
        eval_times = [t.evaluation_s for t in traces]
        llm_after_obs_times = [t.llm_after_obs_s for t in traces]
        tool_times = [t.tool_total_s for t in traces]
        ttfo_times = [t.time_to_first_obs_s for t in traces]
        overhead_times = [t.overhead_s for t in traces]
        total_times = [t.total_latency_s for t in traces]
        llm_counts = [t.llm_count for t in traces]
        tool_counts = [t.tool_count for t in traces]

        print(f"  {'Timing':<30s} {'Avg':>9s} {'P50':>9s} {'P95':>9s} {'Min':>9s} {'Max':>9s}")
        print(f"  {'-' * 30} {'-' * 9} {'-' * 9} {'-' * 9} {'-' * 9} {'-' * 9}")

        def row(label: str, values: list[float]) -> None:
            if not values or all(v == 0 for v in values):
                print(f"  {label:<30s} {'n/a':>9s}")
                return
            print(
                f"  {label:<30s} {avg(values):>9.2f} {percentile(values, 0.5):>9.2f} "
                f"{percentile(values, 0.95):>9.2f} {min(values):>9.2f} {max(values):>9.2f}"
            )

        row("Total (s)", total_times)
        row("Session Creation (s)", creation_times)
        row("Agent Call (s)", agent_times)
        row("  Time to 1st Obs (s)", ttfo_times)
        row("  LLM Calls (s)", llm_after_obs_times)
        row("  Tool Calls (s)", tool_times)
        row("  Overhead (s)", overhead_times)
        row("Evaluation (s)", eval_times)

        print()
        llm_counts_f = [float(x) for x in llm_counts]
        tool_counts_f = [float(x) for x in tool_counts]
        llm_counts_after_obs_f = [float(t.llm_count_after_obs) for t in traces]
        print(f"  Avg LLM calls/session:     {avg(llm_counts_after_obs_f):.1f}  (std: {std(llm_counts_after_obs_f):.1f})")
        print(f"  Avg Tool calls/session:    {avg(tool_counts_f):.1f}  (std: {std(tool_counts_f):.1f})")
        if any(llm_after_obs_times):
            llm_latencies = [t.llm_after_obs_s / max(t.llm_count_after_obs, 1) for t in traces if t.llm_count_after_obs > 0]
            print(f"  Avg LLM call latency:      {avg(llm_latencies):.2f}s  (std: {std(llm_latencies):.2f}s)")
        if any(tool_times):
            tool_latencies = [t.tool_total_s / max(t.tool_count, 1) for t in traces if t.tool_count > 0]
            print(f"  Avg Tool call latency:     {avg(tool_latencies):.2f}s  (std: {std(tool_latencies):.2f}s)")

        # Time breakdown as % of agent call time
        # TTFO = time before first observation (includes first LLM call + startup)
        # LLM = LLM calls AFTER initial observation only
        # Tool = tool calls (excluding initial_observation)
        # Overhead = remaining time (inter-call gaps, serialization, etc.)
        ttfo_pcts = [(t.time_to_first_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0 for t in traces]
        llm_pcts = [(t.llm_after_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0 for t in traces]
        tool_pcts = [(t.tool_total_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0 for t in traces]
        overhead_pcts = [(t.overhead_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0 for t in traces]
        if any(ttfo_pcts):
            print(f"  Avg % time before 1st Obs: {avg(ttfo_pcts):.1f}%  (std: {std(ttfo_pcts):.1f}%)")
        if any(llm_pcts):
            print(f"  Avg % time on LLM calls:   {avg(llm_pcts):.1f}%  (std: {std(llm_pcts):.1f}%)")
        if any(tool_pcts):
            print(f"  Avg % time on Tool calls:  {avg(tool_pcts):.1f}%  (std: {std(tool_pcts):.1f}%)")
        if any(overhead_pcts):
            print(f"  Avg % time overhead:       {avg(overhead_pcts):.1f}%  (std: {std(overhead_pcts):.1f}%)")

        input_tokens = [float(t.llm_input_tokens) for t in traces]
        output_tokens = [float(t.llm_output_tokens) for t in traces]
        total_tokens = [i + o for i, o in zip(input_tokens, output_tokens)]
        if any(input_tokens):
            print(f"  Avg LLM input tokens:      {avg(input_tokens):.0f}  (std: {std(input_tokens):.0f})")
        if any(output_tokens):
            print(f"  Avg LLM output tokens:     {avg(output_tokens):.0f}  (std: {std(output_tokens):.0f})")
        if any(input_tokens) or any(output_tokens):
            print(f"  Avg LLM total tokens:      {avg(total_tokens):.0f}  (std: {std(total_tokens):.0f})")

        # Infrastructure metrics (only from traces that have infra data)
        infra_traces = [t for t in traces if t.has_infra]

        def infra_section(pod_label: str, pod_key: str) -> None:
            if not infra_traces:
                return

            cpu_util = [getattr(t, f"{pod_key}_cpu_utilization_pct") for t in infra_traces]
            throttle = [getattr(t, f"{pod_key}_throttle_pct") for t in infra_traces]
            mem = [getattr(t, f"{pod_key}_memory_max_mb") for t in infra_traces]
            mem_util = [getattr(t, f"{pod_key}_memory_utilization_pct") for t in infra_traces]
            rx = [getattr(t, f"{pod_key}_network_rx_mb") for t in infra_traces]
            tx = [getattr(t, f"{pod_key}_network_tx_mb") for t in infra_traces]

            if not infra_traces:
                return

            print()
            print(f"  Infrastructure ({pod_label} pod, n={len(infra_traces)})   {'Avg':>9s} {'P50':>9s} {'Max':>9s}")
            print(f"  {'-' * 34} {'-' * 9} {'-' * 9} {'-' * 9}")

            def infra_row(label: str, values: list[float], fmt: str = ".2f") -> None:
                print(f"  {label:<34s} {avg(values):>9{fmt}} {percentile(values, 0.5):>9{fmt}} {max(values):>9{fmt}}")

            infra_row("CPU Utilization (%)", cpu_util, ".1f")
            infra_row("CPU Throttle (%)", throttle, ".1f")
            infra_row("Memory Max (MB)", mem, ".0f")
            infra_row("Memory Utilization (%)", mem_util, ".1f")
            infra_row("Network RX (MB)", rx, ".3f")
            infra_row("Network TX (MB)", tx, ".3f")

        infra_section("MCP", "mcp")
        infra_section("A2A", "a2a")
        print()

    # Individual traces
    print("=" * 140)
    print("Individual Traces")
    print("=" * 140)
    print()
    header = (
        f"{'Timestamp':<20s} {'Experiment':<12s} {'Agent':<18s} {'Benchmark':<12s} {'Model':<25s} {'Par':>3s} "
        f"{'Session ID':<38s} {'Stat':<5s} {'Eval':<4s} "
        f"{'Total':>6s} {'Crt':>5s} {'Agt':>6s} {'TTFO':>5s} "
        f"{'LLM':>6s} {'LLM%':>5s} {'Tool':>6s} {'Tool%':>5s} {'Eval':>5s}"
    )
    print(header)
    print("-" * len(header))

    for r in sorted(records, key=lambda x: (x.experiment_name, x.start_time)):
        eval_str = "pass" if r.evaluation_result is True else "fail" if r.evaluation_result is False else "?"
        llm_pct = (r.llm_after_obs_s / r.agent_call_s * 100) if r.agent_call_s > 0 else 0
        tool_pct = (r.tool_total_s / r.agent_call_s * 100) if r.agent_call_s > 0 else 0
        print(
            f"{format_time(r.start_time):<20s} {r.experiment_name:<12s} {r.agent_name:<18s} {r.benchmark_name:<12s} {r.model:<25s} {r.num_parallel:>3d} "
            f"{r.session_id:<38s} {r.status:<5s} {eval_str:<4s} "
            f"{r.total_latency_s:>6.1f} {r.session_creation_s:>5.1f} {r.agent_call_s:>6.1f} {r.time_to_first_obs_s:>5.1f} "
            f"{r.llm_after_obs_s:>6.1f} {llm_pct:>5.1f} {r.tool_total_s:>6.1f} {tool_pct:>5.1f} {r.evaluation_s:>5.1f}"
        )

    print()
    print("All times in seconds. LLM and LLM% are after initial observation only.")
    
    # Comparative analysis: metrics by parallel sessions for each agent/benchmark/model
    print()
    print("=" * 140)
    print("Comparative Analysis: Metrics by Parallel Sessions")
    print("=" * 140)
    print()
    
    # Group by (agent, benchmark, model) and then by parallel sessions
    config_groups: dict[tuple, dict[int, list[TraceRecord]]] = defaultdict(lambda: defaultdict(list))
    
    for r in records:
        config_key = (r.experiment_name, r.agent_name, r.benchmark_name, r.model)
        config_groups[config_key][r.num_parallel].append(r)
    
    # Print a table for each configuration
    for config_key in sorted(config_groups.keys()):
        experiment, agent, benchmark, model = config_key
        parallel_groups = config_groups[config_key]
        
        # Get all parallel values for this config
        parallel_values = sorted(parallel_groups.keys())
        
        if len(parallel_values) < 2:
            # Skip if only one parallel value (no comparison to make)
            continue
        
        print(f"\nAgent: {agent}  |  Benchmark: {benchmark}  |  Model: {model}")
        print("-" * 140)
        
        # Check if any traces have infra data
        has_infra = any(t.has_infra for traces in parallel_groups.values() for t in traces)
        
        # Build header
        header = f"{'Metric':<35s}"
        for p in parallel_values:
            header += f" | {f'Parallel={p}':>12s}"
        print(header)
        print("-" * len(header))
        
        # Helper to print a metric row
        def print_metric_row(label: str, metric_fn, fmt: str = ".2f") -> None:
            row = f"{label:<35s}"
            for p in parallel_values:
                traces = parallel_groups[p]
                values = [metric_fn(t) for t in traces]
                avg_val = avg(values)
                row += f" | {avg_val:>12{fmt}}"
            print(row)
        
        # Count row (not averaged — shows number of traces per group)
        count_row = f"{'Traces (count)':<35s}"
        for p in parallel_values:
            count_row += f" | {len(parallel_groups[p]):>12d}"
        print(count_row)

        # --- Timing (absolute) ---
        print_metric_row("Total Latency (s)", lambda t: t.total_latency_s)
        print_metric_row("Session Creation (s)", lambda t: t.session_creation_s)
        print_metric_row("Agent Call (s)", lambda t: t.agent_call_s)
        print_metric_row("  Time to First Obs (s)", lambda t: t.time_to_first_obs_s)
        print_metric_row("  LLM Calls (s)", lambda t: t.llm_after_obs_s)
        print_metric_row("  Tool Calls (s)", lambda t: t.tool_total_s)
        print_metric_row("  Overhead (s)", lambda t: t.overhead_s)
        print_metric_row("Evaluation (s)", lambda t: t.evaluation_s)

        # --- Timing (% of agent call) ---
        sep = f"{'':35s}"
        for _ in parallel_values:
            sep += f" | {'':>12s}"
        print(sep)
        print_metric_row("% Time before 1st Obs",
                         lambda t: (t.time_to_first_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
        print_metric_row("% Time on LLM calls",
                         lambda t: (t.llm_after_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
        print_metric_row("% Time on Tool calls",
                         lambda t: (t.tool_total_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
        print_metric_row("% Time overhead",
                         lambda t: (t.overhead_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")

        # --- Agent metrics ---
        print(sep)
        print_metric_row("LLM Calls (count)", lambda t: t.llm_count_after_obs, ".1f")
        print_metric_row("Avg LLM Call Latency (s)", lambda t: (t.llm_after_obs_s / max(t.llm_count_after_obs, 1)) if t.llm_count_after_obs > 0 else 0, ".3f")
        print_metric_row("Tool Calls (count)", lambda t: t.tool_count, ".1f")
        print_metric_row("Avg Tool Call Latency (s)", lambda t: (t.tool_total_s / max(t.tool_count, 1)) if t.tool_count > 0 else 0, ".3f")
        print_metric_row("LLM Input Tokens", lambda t: t.llm_input_tokens, ".0f")
        print_metric_row("LLM Output Tokens", lambda t: t.llm_output_tokens, ".0f")
        print_metric_row("LLM Total Tokens", lambda t: t.llm_input_tokens + t.llm_output_tokens, ".0f")

        # --- Success metrics ---
        print(sep)

        def eval_success_rate(traces: list[TraceRecord]) -> float:
            n = len(traces)
            success = sum(1 for t in traces if t.evaluation_result is True)
            return (success / n * 100) if n > 0 else 0.0

        eval_row = f"{'Evaluation Success Rate (%)':<35s}"
        for p in parallel_values:
            traces = parallel_groups[p]
            eval_row += f" | {eval_success_rate(traces):>12.1f}"
        print(eval_row)

        def error_rate(traces: list[TraceRecord]) -> float:
            n = len(traces)
            errors = sum(1 for t in traces if t.status == "ERROR")
            return (errors / n * 100) if n > 0 else 0.0

        err_row = f"{'Error Rate (%)':<35s}"
        for p in parallel_values:
            traces = parallel_groups[p]
            err_row += f" | {error_rate(traces):>12.1f}"
        print(err_row)
        
        # Infrastructure metrics (if available)
        if has_infra:
            print()
            print("Infrastructure Metrics (from traces with infra data):")
            print("-" * len(header))
            
            # MCP metrics
            print_metric_row("MCP CPU Utilization (%)", lambda t: t.mcp_cpu_utilization_pct if t.has_infra else 0, ".1f")
            print_metric_row("MCP CPU Throttle (%)", lambda t: t.mcp_throttle_pct if t.has_infra else 0, ".1f")
            print_metric_row("MCP Memory Max (MB)", lambda t: t.mcp_memory_max_mb if t.has_infra else 0, ".0f")
            print_metric_row("MCP Memory Utilization (%)", lambda t: t.mcp_memory_utilization_pct if t.has_infra else 0, ".1f")
            print_metric_row("MCP Network RX (MB)", lambda t: t.mcp_network_rx_mb if t.has_infra else 0, ".3f")
            print_metric_row("MCP Network TX (MB)", lambda t: t.mcp_network_tx_mb if t.has_infra else 0, ".3f")
            
            # A2A metrics
            print_metric_row("A2A CPU Utilization (%)", lambda t: t.a2a_cpu_utilization_pct if t.has_infra else 0, ".1f")
            print_metric_row("A2A CPU Throttle (%)", lambda t: t.a2a_throttle_pct if t.has_infra else 0, ".1f")
            print_metric_row("A2A Memory Max (MB)", lambda t: t.a2a_memory_max_mb if t.has_infra else 0, ".0f")
            print_metric_row("A2A Memory Utilization (%)", lambda t: t.a2a_memory_utilization_pct if t.has_infra else 0, ".1f")
            print_metric_row("A2A Network RX (MB)", lambda t: t.a2a_network_rx_mb if t.has_infra else 0, ".3f")
            print_metric_row("A2A Network TX (MB)", lambda t: t.a2a_network_tx_mb if t.has_infra else 0, ".3f")
        
        print()


def print_experiment_comparison(records: list[TraceRecord]) -> None:
    """Print comparison report between experiments."""
    if not records:
        print("No traces to compare.")
        return

    experiments = sorted(set(r.experiment_name for r in records))

    if len(experiments) < 2:
        print(f"Only one experiment found: {experiments[0] if experiments else 'none'}")
        print("Need at least 2 experiments to compare.")
        return

    exp_groups: dict[str, list[TraceRecord]] = defaultdict(list)
    for r in records:
        exp_groups[r.experiment_name].append(r)

    has_infra = any(t.has_infra for traces in exp_groups.values() for t in traces)

    col_w = max(20, max(len(e) for e in experiments) + 2)

    print()
    print("=" * 140)
    print(f"Experiment Comparison: {' vs '.join(experiments)}")
    print("=" * 140)
    print()

    header = f"{'Metric':<35s}"
    for exp in experiments:
        header += f" | {exp:>{col_w}s}"
    print(header)
    print("-" * len(header))

    def print_metric_row(label: str, metric_fn, fmt: str = ".2f") -> None:
        row = f"{label:<35s}"
        for exp in experiments:
            traces = exp_groups[exp]
            values = [metric_fn(t) for t in traces]
            row += f" | {avg(values):>{col_w}{fmt}}"
        print(row)

    count_row = f"{'Traces (count)':<35s}"
    for exp in experiments:
        count_row += f" | {len(exp_groups[exp]):>{col_w}d}"
    print(count_row)

    eval_row = f"{'Eval Success Rate (%)':<35s}"
    for exp in experiments:
        traces = exp_groups[exp]
        n = len(traces)
        rate = sum(1 for t in traces if t.evaluation_result is True) / n * 100 if n else 0
        eval_row += f" | {rate:>{col_w}.1f}"
    print(eval_row)

    print_metric_row("Total Latency (s)", lambda t: t.total_latency_s)
    print_metric_row("Session Creation (s)", lambda t: t.session_creation_s)
    print_metric_row("Agent Call (s)", lambda t: t.agent_call_s)
    print_metric_row("  Time to First Obs (s)", lambda t: t.time_to_first_obs_s)
    print_metric_row("  LLM Calls (s)", lambda t: t.llm_after_obs_s)
    print_metric_row("  Tool Calls (s)", lambda t: t.tool_total_s)
    print_metric_row("  Overhead (s)", lambda t: t.overhead_s)
    print_metric_row("Evaluation (s)", lambda t: t.evaluation_s)

    sep = f"{'':35s}" + (f" | {'':>{col_w}s}" * len(experiments))
    print(sep)
    print_metric_row("% Time before 1st Obs",
                     lambda t: (t.time_to_first_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
    print_metric_row("% Time on LLM calls",
                     lambda t: (t.llm_after_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
    print_metric_row("% Time on Tool calls",
                     lambda t: (t.tool_total_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")
    print_metric_row("% Time overhead",
                     lambda t: (t.overhead_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0, ".1f")

    print(sep)
    print_metric_row("LLM Calls (count)", lambda t: t.llm_count_after_obs, ".1f")
    print_metric_row("Avg LLM Call Latency (s)",
                     lambda t: (t.llm_after_obs_s / t.llm_count_after_obs) if t.llm_count_after_obs > 0 else 0, ".3f")
    print_metric_row("Tool Calls (count)", lambda t: t.tool_count, ".1f")
    print_metric_row("Avg Tool Call Latency (s)",
                     lambda t: (t.tool_total_s / t.tool_count) if t.tool_count > 0 else 0, ".3f")
    print_metric_row("LLM Input Tokens", lambda t: t.llm_input_tokens, ".0f")
    print_metric_row("LLM Output Tokens", lambda t: t.llm_output_tokens, ".0f")
    print_metric_row("LLM Total Tokens", lambda t: t.llm_input_tokens + t.llm_output_tokens, ".0f")

    if has_infra:
        print(sep)
        print_metric_row("MCP CPU Utilization (%)", lambda t: t.mcp_cpu_utilization_pct if t.has_infra else 0, ".1f")
        print_metric_row("MCP CPU Throttle (%)", lambda t: t.mcp_throttle_pct if t.has_infra else 0, ".1f")
        print_metric_row("MCP Memory Max (MB)", lambda t: t.mcp_memory_max_mb if t.has_infra else 0, ".0f")
        print_metric_row("MCP Memory Utilization (%)", lambda t: t.mcp_memory_utilization_pct if t.has_infra else 0, ".1f")
        print_metric_row("MCP Network RX (MB)", lambda t: t.mcp_network_rx_mb if t.has_infra else 0, ".3f")
        print_metric_row("MCP Network TX (MB)", lambda t: t.mcp_network_tx_mb if t.has_infra else 0, ".3f")
        print_metric_row("A2A CPU Utilization (%)", lambda t: t.a2a_cpu_utilization_pct if t.has_infra else 0, ".1f")
        print_metric_row("A2A CPU Throttle (%)", lambda t: t.a2a_throttle_pct if t.has_infra else 0, ".1f")
        print_metric_row("A2A Memory Max (MB)", lambda t: t.a2a_memory_max_mb if t.has_infra else 0, ".0f")
        print_metric_row("A2A Memory Utilization (%)", lambda t: t.a2a_memory_utilization_pct if t.has_infra else 0, ".1f")
        print_metric_row("A2A Network RX (MB)", lambda t: t.a2a_network_rx_mb if t.has_infra else 0, ".3f")
        print_metric_row("A2A Network TX (MB)", lambda t: t.a2a_network_tx_mb if t.has_infra else 0, ".3f")

    print()


def main() -> int:
    import argparse
    
    parser = argparse.ArgumentParser(description="Analyze Phoenix agent traces")
    parser.add_argument("file", nargs="?", help="JSON file to read (default: stdin)")
    parser.add_argument("--compare", action="store_true", help="Enable comparison mode (currently unused, for future enhancements)")
    args = parser.parse_args()
    
    if args.file and args.file != "-":
        with open(args.file) as f:
            raw = json.load(f)
    else:
        raw = json.load(sys.stdin)

    records = parse_traces(raw)

    if args.compare:
        print_experiment_comparison(records)
    else:
        print_report(records)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
