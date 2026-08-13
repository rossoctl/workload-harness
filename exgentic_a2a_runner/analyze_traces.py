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
from dataclasses import asdict, dataclass, field
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
    status_message: str = ""

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
        status_message = root.get("statusMessage", "")
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
            status_message=status_message,
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
            # Token usage from the OpenTelemetry gen_ai semantic-convention keys
            # (gen_ai.usage.input_tokens/output_tokens) that current tracers emit.
            gen_ai_usage = child_attrs.get("gen_ai", {}).get("usage", {})
            record.llm_input_tokens += int(gen_ai_usage.get("input_tokens", 0) or 0)
            record.llm_output_tokens += int(gen_ai_usage.get("output_tokens", 0) or 0)

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


def record_to_dict(r: TraceRecord) -> dict:
    """Serialize a TraceRecord to a JSON-friendly dict (all fields are scalars/None)."""
    return asdict(r)


def _timing_stats(values: list[float]) -> dict:
    """avg/p50/p95/min/max for a timing series (0.0 across the board when empty)."""
    if not values:
        return {"avg": 0.0, "p50": 0.0, "p95": 0.0, "min": 0.0, "max": 0.0}
    return {
        "avg": avg(values),
        "p50": percentile(values, 0.5),
        "p95": percentile(values, 0.95),
        "min": min(values),
        "max": max(values),
    }


def build_group_summaries(records: list[TraceRecord]) -> list[dict]:
    """Aggregate per-group statistics mirroring the printed report.

    Groups by (experiment_name, agent_name, benchmark_name, model, num_parallel)
    and reuses the same avg/percentile/std helpers used to print the tables.
    """
    groups: dict[tuple, list[TraceRecord]] = defaultdict(list)
    for r in records:
        key = (r.experiment_name, r.agent_name, r.benchmark_name, r.model, r.num_parallel)
        groups[key].append(r)

    summaries: list[dict] = []
    for key, traces in sorted(groups.items()):
        experiment, agent, benchmark, model, num_parallel = key
        n = len(traces)
        errors = sum(1 for t in traces if t.status == "ERROR")
        eval_success = sum(1 for t in traces if t.evaluation_result is True)

        llm_counts_after_obs = [float(t.llm_count_after_obs) for t in traces]
        tool_counts = [float(t.tool_count) for t in traces]
        input_tokens = [float(t.llm_input_tokens) for t in traces]
        output_tokens = [float(t.llm_output_tokens) for t in traces]
        total_tokens = [i + o for i, o in zip(input_tokens, output_tokens)]

        summary = {
            "experiment_name": experiment,
            "agent_name": agent,
            "benchmark_name": benchmark,
            "model": model,
            "num_parallel": num_parallel,
            "counts": {
                "traces": n,
                "errors": errors,
                "eval_success": eval_success,
            },
            "timing": {
                "total": _timing_stats([t.total_latency_s for t in traces]),
                "session_creation": _timing_stats([t.session_creation_s for t in traces]),
                "agent_call": _timing_stats([t.agent_call_s for t in traces]),
                "time_to_first_obs": _timing_stats([t.time_to_first_obs_s for t in traces]),
                "llm_after_obs": _timing_stats([t.llm_after_obs_s for t in traces]),
                "tool_total": _timing_stats([t.tool_total_s for t in traces]),
                "overhead": _timing_stats([t.overhead_s for t in traces]),
                "evaluation": _timing_stats([t.evaluation_s for t in traces]),
            },
            "llm_calls_after_obs": {"avg": avg(llm_counts_after_obs), "std": std(llm_counts_after_obs)},
            "tool_calls": {"avg": avg(tool_counts), "std": std(tool_counts)},
            "input_tokens": {"avg": avg(input_tokens), "std": std(input_tokens)},
            "output_tokens": {"avg": avg(output_tokens), "std": std(output_tokens)},
            "total_tokens": {"avg": avg(total_tokens), "std": std(total_tokens)},
        }

        # Per-trace latency averages (only for traces that had calls)
        llm_latencies = [t.llm_after_obs_s / t.llm_count_after_obs for t in traces if t.llm_count_after_obs > 0]
        tool_latencies = [t.tool_total_s / t.tool_count for t in traces if t.tool_count > 0]
        summary["llm_call_latency_s"] = {"avg": avg(llm_latencies), "std": std(llm_latencies)}
        summary["tool_call_latency_s"] = {"avg": avg(tool_latencies), "std": std(tool_latencies)}

        # % of agent call time
        ttfo_pcts = [(t.time_to_first_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0.0 for t in traces]
        llm_pcts = [(t.llm_after_obs_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0.0 for t in traces]
        tool_pcts = [(t.tool_total_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0.0 for t in traces]
        overhead_pcts = [(t.overhead_s / t.agent_call_s * 100) if t.agent_call_s > 0 else 0.0 for t in traces]
        summary["ttfo_pct"] = {"avg": avg(ttfo_pcts), "std": std(ttfo_pcts)}
        summary["llm_pct"] = {"avg": avg(llm_pcts), "std": std(llm_pcts)}
        summary["tool_pct"] = {"avg": avg(tool_pcts), "std": std(tool_pcts)}
        summary["overhead_pct"] = {"avg": avg(overhead_pcts), "std": std(overhead_pcts)}

        infra_traces = [t for t in traces if t.has_infra]
        if infra_traces:
            infra: dict = {"n": len(infra_traces)}
            for pod_key in ("mcp", "a2a"):
                pod_stats = {}
                for metric in (
                    "cpu_utilization_pct",
                    "throttle_pct",
                    "memory_max_mb",
                    "memory_utilization_pct",
                    "network_rx_mb",
                    "network_tx_mb",
                ):
                    vals = [getattr(t, f"{pod_key}_{metric}") for t in infra_traces]
                    pod_stats[metric] = {
                        "avg": avg(vals),
                        "p50": percentile(vals, 0.5),
                        "max": max(vals) if vals else 0.0,
                    }
                infra[pod_key] = pod_stats
            summary["infra"] = infra

        summaries.append(summary)

    return summaries


def build_analysis_json(records: list[TraceRecord]) -> dict:
    """Full analysis payload: per-trace records plus aggregated group summaries."""
    return {
        "traces": [record_to_dict(r) for r in records],
        "groups": build_group_summaries(records),
    }


def print_report(records: list[TraceRecord]) -> None:
    if not records:
        print("No Agent.Session traces found.")
        return

    summaries = build_group_summaries(records)

    for s in summaries:
        experiment = s["experiment_name"]
        agent = s["agent_name"]
        benchmark = s["benchmark_name"]
        model = s["model"]
        num_parallel = s["num_parallel"]
        counts = s["counts"]
        n = counts["traces"]
        errors = counts["errors"]
        eval_success = counts["eval_success"]
        timing = s["timing"]

        print("=" * 100)
        print(f"Experiment: {experiment}  |  Agent: {agent}  |  Benchmark: {benchmark}  |  Model: {model}  |  Parallel: {num_parallel}")
        print("=" * 100)
        print()

        print(f"  Traces:              {n}")
        print(f"  Errors:              {errors}")
        print(f"  Eval Success:        {eval_success}/{n} ({eval_success / n * 100:.0f}%)")
        print()

        print(f"  {'Timing':<30s} {'Avg':>9s} {'P50':>9s} {'P95':>9s} {'Min':>9s} {'Max':>9s}")
        print(f"  {'-' * 30} {'-' * 9} {'-' * 9} {'-' * 9} {'-' * 9} {'-' * 9}")

        def row(label: str, ts: dict) -> None:
            if ts["avg"] == 0 and ts["max"] == 0:
                print(f"  {label:<30s} {'n/a':>9s}")
                return
            print(
                f"  {label:<30s} {ts['avg']:>9.2f} {ts['p50']:>9.2f} "
                f"{ts['p95']:>9.2f} {ts['min']:>9.2f} {ts['max']:>9.2f}"
            )

        row("Total (s)", timing["total"])
        row("Session Creation (s)", timing["session_creation"])
        row("Agent Call (s)", timing["agent_call"])
        row("  Time to 1st Obs (s)", timing["time_to_first_obs"])
        row("  LLM Calls (s)", timing["llm_after_obs"])
        row("  Tool Calls (s)", timing["tool_total"])
        row("  Overhead (s)", timing["overhead"])
        row("Evaluation (s)", timing["evaluation"])

        print()
        llm = s["llm_calls_after_obs"]
        tools = s["tool_calls"]
        print(f"  Avg LLM calls/session:     {llm['avg']:.1f}  (std: {llm['std']:.1f})")
        print(f"  Avg Tool calls/session:    {tools['avg']:.1f}  (std: {tools['std']:.1f})")
        if llm["avg"] > 0:
            print(f"  Avg LLM call latency:      {s['llm_call_latency_s']['avg']:.2f}s  (std: {s['llm_call_latency_s']['std']:.2f}s)")
        if tools["avg"] > 0:
            print(f"  Avg Tool call latency:     {s['tool_call_latency_s']['avg']:.2f}s  (std: {s['tool_call_latency_s']['std']:.2f}s)")

        ac = timing["agent_call"]["avg"]
        if ac > 0:
            ttfo_pct = s["ttfo_pct"]
            llm_pct = s["llm_pct"]
            tool_pct = s["tool_pct"]
            oh_pct = s["overhead_pct"]
            if ttfo_pct["avg"] > 0:
                print(f"  Avg % time before 1st Obs: {ttfo_pct['avg']:.1f}%  (std: {ttfo_pct['std']:.1f}%)")
            if llm_pct["avg"] > 0:
                print(f"  Avg % time on LLM calls:   {llm_pct['avg']:.1f}%  (std: {llm_pct['std']:.1f}%)")
            if tool_pct["avg"] > 0:
                print(f"  Avg % time on Tool calls:  {tool_pct['avg']:.1f}%  (std: {tool_pct['std']:.1f}%)")
            if oh_pct["avg"] > 0:
                print(f"  Avg % time overhead:       {oh_pct['avg']:.1f}%  (std: {oh_pct['std']:.1f}%)")

        inp = s["input_tokens"]
        out = s["output_tokens"]
        tot = s["total_tokens"]
        if inp["avg"] > 0:
            print(f"  Avg LLM input tokens:      {inp['avg']:.0f}  (std: {inp['std']:.0f})")
        if out["avg"] > 0:
            print(f"  Avg LLM output tokens:     {out['avg']:.0f}  (std: {out['std']:.0f})")
        if inp["avg"] > 0 or out["avg"] > 0:
            print(f"  Avg LLM total tokens:      {tot['avg']:.0f}  (std: {tot['std']:.0f})")

        if "infra" in s:
            infra = s["infra"]
            for pod_key, pod_label in (("mcp", "MCP"), ("a2a", "A2A")):
                pod = infra.get(pod_key, {})
                if not pod:
                    continue
                n_infra = infra["n"]
                print()
                print(f"  Infrastructure ({pod_label} pod, n={n_infra})   {'Avg':>9s} {'P50':>9s} {'Max':>9s}")
                print(f"  {'-' * 34} {'-' * 9} {'-' * 9} {'-' * 9}")

                def infra_row(label: str, metric: str, fmt: str) -> None:
                    m = pod[metric]
                    print(f"  {label:<34s} {m['avg']:>9{fmt}} {m['p50']:>9{fmt}} {m['max']:>9{fmt}}")

                infra_row("CPU Utilization (%)", "cpu_utilization_pct", ".1f")
                infra_row("CPU Throttle (%)", "throttle_pct", ".1f")
                infra_row("Memory Max (MB)", "memory_max_mb", ".0f")
                infra_row("Memory Utilization (%)", "memory_utilization_pct", ".1f")
                infra_row("Network RX (MB)", "network_rx_mb", ".3f")
                infra_row("Network TX (MB)", "network_tx_mb", ".3f")

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

    # Comparative analysis: metrics by parallel sessions — driven from summaries
    print()
    print("=" * 140)
    print("Comparative Analysis: Metrics by Parallel Sessions")
    print("=" * 140)
    print()

    # Group summaries by (experiment, agent, benchmark, model) then by num_parallel
    config_groups: dict[tuple, dict[int, dict]] = defaultdict(dict)
    for s in summaries:
        config_key = (s["experiment_name"], s["agent_name"], s["benchmark_name"], s["model"])
        config_groups[config_key][s["num_parallel"]] = s

    for config_key in sorted(config_groups.keys()):
        experiment, agent, benchmark, model = config_key
        parallel_map = config_groups[config_key]
        parallel_values = sorted(parallel_map.keys())

        if len(parallel_values) < 2:
            continue

        print(f"\nAgent: {agent}  |  Benchmark: {benchmark}  |  Model: {model}")
        print("-" * 140)

        has_infra = any("infra" in parallel_map[p] for p in parallel_values)

        col_header = f"{'Metric':<35s}"
        for p in parallel_values:
            col_header += f" | {f'Parallel={p}':>12s}"
        print(col_header)
        print("-" * len(col_header))

        def smrow(label: str, getter, fmt: str = ".2f") -> None:
            line = f"{label:<35s}"
            for p in parallel_values:
                line += f" | {getter(parallel_map[p]):>12{fmt}}"
            print(line)

        count_row = f"{'Traces (count)':<35s}"
        for p in parallel_values:
            count_row += f" | {parallel_map[p]['counts']['traces']:>12d}"
        print(count_row)

        smrow("Total Latency (s)", lambda s: s["timing"]["total"]["avg"])
        smrow("Session Creation (s)", lambda s: s["timing"]["session_creation"]["avg"])
        smrow("Agent Call (s)", lambda s: s["timing"]["agent_call"]["avg"])
        smrow("  Time to First Obs (s)", lambda s: s["timing"]["time_to_first_obs"]["avg"])
        smrow("  LLM Calls (s)", lambda s: s["timing"]["llm_after_obs"]["avg"])
        smrow("  Tool Calls (s)", lambda s: s["timing"]["tool_total"]["avg"])
        smrow("  Overhead (s)", lambda s: s["timing"]["overhead"]["avg"])
        smrow("Evaluation (s)", lambda s: s["timing"]["evaluation"]["avg"])

        sep = f"{'':35s}" + f" | {'':>12s}" * len(parallel_values)
        print(sep)
        smrow("% Time before 1st Obs", lambda s: s["ttfo_pct"]["avg"], ".1f")
        smrow("% Time on LLM calls", lambda s: s["llm_pct"]["avg"], ".1f")
        smrow("% Time on Tool calls", lambda s: s["tool_pct"]["avg"], ".1f")
        smrow("% Time overhead", lambda s: s["overhead_pct"]["avg"], ".1f")

        print(sep)
        smrow("LLM Calls (count)", lambda s: s["llm_calls_after_obs"]["avg"], ".1f")
        smrow("Avg LLM Call Latency (s)", lambda s: s["llm_call_latency_s"]["avg"], ".3f")
        smrow("Tool Calls (count)", lambda s: s["tool_calls"]["avg"], ".1f")
        smrow("Avg Tool Call Latency (s)", lambda s: s["tool_call_latency_s"]["avg"], ".3f")
        smrow("LLM Input Tokens", lambda s: s["input_tokens"]["avg"], ".0f")
        smrow("LLM Output Tokens", lambda s: s["output_tokens"]["avg"], ".0f")
        smrow("LLM Total Tokens", lambda s: s["total_tokens"]["avg"], ".0f")

        print(sep)
        smrow("Evaluation Success Rate (%)",
              lambda s: (s["counts"]["eval_success"] / s["counts"]["traces"] * 100)
              if s["counts"]["traces"] > 0 else 0.0, ".1f")
        smrow("Error Rate (%)",
              lambda s: (s["counts"]["errors"] / s["counts"]["traces"] * 100)
              if s["counts"]["traces"] > 0 else 0.0, ".1f")

        if has_infra:
            print()
            print("Infrastructure Metrics (from traces with infra data):")
            print("-" * len(col_header))
            for pod_key, pod_label in (("mcp", "MCP"), ("a2a", "A2A")):
                smrow(f"{pod_label} CPU Utilization (%)",
                      lambda s, pk=pod_key: s["infra"][pk]["cpu_utilization_pct"]["avg"] if "infra" in s else 0, ".1f")
                smrow(f"{pod_label} CPU Throttle (%)",
                      lambda s, pk=pod_key: s["infra"][pk]["throttle_pct"]["avg"] if "infra" in s else 0, ".1f")
                smrow(f"{pod_label} Memory Max (MB)",
                      lambda s, pk=pod_key: s["infra"][pk]["memory_max_mb"]["avg"] if "infra" in s else 0, ".0f")
                smrow(f"{pod_label} Memory Utilization (%)",
                      lambda s, pk=pod_key: s["infra"][pk]["memory_utilization_pct"]["avg"] if "infra" in s else 0, ".1f")
                smrow(f"{pod_label} Network RX (MB)",
                      lambda s, pk=pod_key: s["infra"][pk]["network_rx_mb"]["avg"] if "infra" in s else 0, ".3f")
                smrow(f"{pod_label} Network TX (MB)",
                      lambda s, pk=pod_key: s["infra"][pk]["network_tx_mb"]["avg"] if "infra" in s else 0, ".3f")

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

    err_row = f"{'Error Rate (%)':<35s}"
    for exp in experiments:
        traces = exp_groups[exp]
        n = len(traces)
        rate = sum(1 for t in traces if t.status == "ERROR") / n * 100 if n else 0
        err_row += f" | {rate:>{col_w}.1f}"
    print(err_row)

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

    # --- Error breakdown by type (verbatim root statusMessage) ---
    # Count each ERROR-status root span under its statusMessage, per experiment.
    # ERROR traces with no message are grouped under "(no message)".
    A2A_PREFIX = "A2A task ended in state 'failed':"

    def error_label(t: TraceRecord) -> str:
        msg = (t.status_message or "").splitlines()[0].strip() if t.status_message else ""
        if msg.startswith(A2A_PREFIX):
            msg = msg[len(A2A_PREFIX):].strip()
        if not msg:
            return "(no message)"
        return msg if len(msg) <= 100 else msg[:97] + "..."

    # error type -> {experiment -> count}
    err_counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for r in records:
        if r.status == "ERROR":
            err_counts[error_label(r)][r.experiment_name] += 1

    print("=" * 140)
    print("Error Breakdown by Type")
    print("=" * 140)
    print()

    if not err_counts:
        print("No errors in any experiment.")
        print()
    else:
        err_header = f"{'Error Type':<100s}"
        for exp in experiments:
            err_header += f" | {exp:>{col_w}s}"
        print(err_header)
        print("-" * len(err_header))

        # Sort error types by total count across experiments (most frequent first)
        for err_type in sorted(err_counts, key=lambda e: -sum(err_counts[e].values())):
            row = f"{err_type:<100s}"
            for exp in experiments:
                count = err_counts[err_type].get(exp, 0)
                total = len(exp_groups[exp])
                pct = (count / total * 100) if total else 0
                row += f" | {f'{count} ({pct:.0f}%)':>{col_w}s}"
            print(row)
        print()


def main() -> int:
    import argparse
    
    parser = argparse.ArgumentParser(description="Analyze Phoenix agent traces")
    parser.add_argument("file", nargs="?", help="JSON file to read (default: stdin)")
    parser.add_argument("--compare", action="store_true", help="Enable comparison mode (currently unused, for future enhancements)")
    parser.add_argument("--json", dest="json_path", metavar="PATH",
                        help="Also write the computed analysis (per-trace records + group summaries) as JSON to PATH")
    args = parser.parse_args()

    if args.file and args.file != "-":
        with open(args.file) as f:
            raw = json.load(f)
    else:
        raw = json.load(sys.stdin)

    records = parse_traces(raw)

    if args.json_path:
        with open(args.json_path, "w") as f:
            json.dump(build_analysis_json(records), f, indent=2)

    if args.compare:
        print_experiment_comparison(records)
    else:
        print_report(records)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
