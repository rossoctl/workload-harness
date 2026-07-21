#!/usr/bin/env python3
"""Download traces from MLflow and output in analyze_traces.py format.

Reads configuration from environment variables:
    MLFLOW_URL          - MLflow base URL (e.g. http://localhost:8081)
    OAUTH_TOKEN         - Bearer token for auth
    EXPERIMENT_ID       - MLflow experiment ID (default: 0)
    WINDOW_MS           - Only fetch traces newer than this many milliseconds
                          ago (default: 10800000 = 3h). The listing is paged
                          newest-first and stops at the first older trace.
    EXPERIMENT_FILTER   - Filter by experiment_name attribute
    COMPARE_EXPERIMENTS - Comma-separated experiment names to include
    MLFLOW_WORKSPACE    - Workspace context; sent as x-mlflow-workspace header
                          when set (required by RHOAI-managed MLflow)
    MLFLOW_INSECURE_TLS - "true" to skip TLS cert verification (needed when
                          reaching a reencrypt HTTPS endpoint via port-forward)
    MIN_DURATION_S      - Skip traces shorter than this (seconds, default 0.1)
                          at the listing stage; their spans are never fetched.

Outputs JSON to stdout: {"traces": [{"traceId": ..., "spans": [...]}]}
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

MLFLOW_URL = os.environ["MLFLOW_URL"]
TOKEN = os.environ["OAUTH_TOKEN"]
EXPERIMENT_ID = os.environ.get("EXPERIMENT_ID", "0")
# Time window: fetch traces from the last WINDOW_MS milliseconds (default 3h).
WINDOW_MS = int(os.environ.get("WINDOW_MS", str(3 * 3600 * 1000)))
EXPERIMENT_FILTER = os.environ.get("EXPERIMENT_FILTER", "")
COMPARE_EXPERIMENTS = os.environ.get("COMPARE_EXPERIMENTS", "")
MLFLOW_WORKSPACE = os.environ.get("MLFLOW_WORKSPACE", "")
MLFLOW_INSECURE_TLS = os.environ.get("MLFLOW_INSECURE_TLS", "false").lower() == "true"
# Skip trivially short traces (agent-card probes, health checks) that have no
# real request. Filtered from the listing before spans are fetched. In seconds.
MIN_DURATION_S = float(os.environ.get("MIN_DURATION_S", "0.1"))

CUTOFF_MS = int(time.time() * 1000) - WINDOW_MS

# When talking to a port-forwarded reencrypt HTTPS endpoint the cert won't
# validate against localhost, so allow opting out of verification.
_SSL_CONTEXT = ssl._create_unverified_context() if MLFLOW_INSECURE_TLS else None


def mlflow_get(path: str) -> dict:
    url = f"{MLFLOW_URL}{path}"
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    }
    # RHOAI MLflow requires a workspace context on every request.
    if MLFLOW_WORKSPACE:
        headers["x-mlflow-workspace"] = MLFLOW_WORKSPACE
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as resp:
        return json.loads(resp.read())


def _is_long_enough(trace: dict) -> bool:
    """True if the trace ran at least MIN_DURATION_S.

    Filters out trivially short traces (agent-card probes / health checks with a
    null request) at the listing stage, so their spans are never fetched. A
    trace with no reported duration is kept — we can't prove it is short.
    """
    ms = trace.get("execution_time_ms")
    if ms is None:
        return True
    return (ms / 1000.0) >= MIN_DURATION_S


def fetch_trace_list() -> list[dict]:
    """Fetch traces within the time window, dropping too-short traces.

    The listing is paged newest-first (descending timestamp_ms), so we stop as
    soon as we reach a trace older than CUTOFF_MS — older pages are never
    requested. Traces shorter than MIN_DURATION_S are filtered here, before any
    span download.
    """
    kept: list[dict] = []
    skipped_short = 0
    page_token = None
    page_size = 500
    reached_cutoff = False

    while not reached_cutoff:
        url = f"/api/2.0/mlflow/traces?experiment_ids={EXPERIMENT_ID}&max_results={page_size}"
        if page_token:
            url += f"&page_token={page_token}"

        response = mlflow_get(url)
        traces = response.get("traces", [])
        for t in traces:
            ts = t.get("timestamp_ms")
            # Newest-first ordering: once older than the window, we are done.
            if ts is not None and ts < CUTOFF_MS:
                reached_cutoff = True
                break
            if _is_long_enough(t):
                kept.append(t)
            else:
                skipped_short += 1

        page_token = response.get("next_page_token")
        if not page_token or not traces:
            break

    if skipped_short:
        print(
            f"Skipped {skipped_short} traces shorter than {MIN_DURATION_S}s "
            f"(not fetched)",
            file=sys.stderr,
        )

    return kept


def transform_spans(raw_spans: list[dict]) -> list[dict]:
    """Transform MLflow OTLP spans to analyze_traces.py format."""
    converted = []
    for span in raw_spans:
        span_id = span.get("span_id", "")
        parent_span_id = span.get("parent_span_id")

        start_ns = span.get("start_time_unix_nano", 0)
        end_ns = span.get("end_time_unix_nano", 0)
        latency_ms = (end_ns - start_ns) / 1_000_000 if start_ns and end_ns else 0

        start_time_iso = ""
        if start_ns:
            start_time_iso = datetime.fromtimestamp(
                start_ns / 1_000_000_000, tz=timezone.utc
            ).isoformat()

        # Parse status
        status = span.get("status", {})
        status_code = status.get("code", "UNSET") if isinstance(status, dict) else "UNSET"
        status_message = status.get("message", "") if isinstance(status, dict) else ""
        status_map = {
            "STATUS_CODE_OK": "OK",
            "STATUS_CODE_ERROR": "ERROR",
            "STATUS_CODE_UNSET": "UNSET",
        }
        status_code = status_map.get(status_code, status_code)

        # Parse OTLP attributes list to nested dict
        raw_attrs = span.get("attributes", [])
        flat_attrs: dict = {}
        for item in raw_attrs:
            key = item.get("key", "")
            value = item.get("value", {})
            if isinstance(value, dict):
                for vtype in ("string_value", "int_value", "double_value", "bool_value"):
                    if vtype in value:
                        flat_attrs[key] = value[vtype]
                        break
            else:
                flat_attrs[key] = value

        # Nest dotted keys and skip mlflow internals
        nested_attrs: dict = {}
        for k, v in flat_attrs.items():
            if k.startswith("mlflow."):
                continue
            parts = k.split(".")
            d = nested_attrs
            for part in parts[:-1]:
                existing = d.get(part)
                if not isinstance(existing, dict):
                    d[part] = {}
                d = d[part]
            d[parts[-1]] = v

        converted.append({
            "name": span.get("name", ""),
            "spanKind": "INTERNAL",
            "statusCode": status_code,
            "statusMessage": status_message,
            "latencyMs": latency_ms,
            "startTime": start_time_iso,
            "parentId": parent_span_id,
            "context": {
                "traceId": span.get("trace_id", ""),
                "spanId": span_id,
            },
            "attributes": nested_attrs,
        })

    return converted


def main() -> int:
    window_h = WINDOW_MS / 3600000.0
    print(
        f"Fetching traces from MLflow (experiment_id={EXPERIMENT_ID}, "
        f"window={window_h:g}h)...",
        file=sys.stderr,
    )

    all_traces = fetch_trace_list()
    real_traces = [t for t in all_traces if t.get("status") in ("OK", "ERROR")]
    print(f"Found {len(all_traces)} total traces, {len(real_traces)} completed (OK/ERROR)", file=sys.stderr)

    if not real_traces:
        print("No completed traces found.", file=sys.stderr)
        print(json.dumps({"traces": []}))
        return 0

    print(f"Downloading spans for {len(real_traces)} traces...", file=sys.stderr)
    output_traces = []

    for i, trace_info in enumerate(real_traces):
        request_id = trace_info.get("request_id", "")
        if not request_id:
            continue

        try:
            trace_data = mlflow_get(f"/api/3.0/mlflow/traces/get?trace_id={request_id}")
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            print(f"  Warning: Failed to fetch trace {request_id}: {e}", file=sys.stderr)
            continue

        raw_spans = trace_data.get("trace", {}).get("spans", [])
        if not raw_spans:
            continue

        converted_spans = transform_spans(raw_spans)
        if not converted_spans:
            continue

        has_session = any(s["name"] == "Agent.Session" for s in converted_spans)
        if not has_session:
            continue

        output_traces.append({
            "traceId": request_id,
            "spans": converted_spans,
        })

        if (i + 1) % 10 == 0:
            print(
                f"  Downloaded {i + 1}/{len(real_traces)} traces "
                f"({len(output_traces)} with Agent.Session)...",
                file=sys.stderr,
            )

    print(f"Downloaded {len(output_traces)} traces with Agent.Session spans", file=sys.stderr)

    # Apply experiment filter
    if EXPERIMENT_FILTER or COMPARE_EXPERIMENTS:
        allowed = set()
        if EXPERIMENT_FILTER:
            allowed.add(EXPERIMENT_FILTER)
        if COMPARE_EXPERIMENTS:
            allowed.update(COMPARE_EXPERIMENTS.split(","))

        filtered = []
        for trace in output_traces:
            for span in trace["spans"]:
                if span["name"] == "Agent.Session":
                    exp_name = span.get("attributes", {}).get("metadata", {}).get("experiment_name", "default")
                    if exp_name in allowed:
                        filtered.append(trace)
                    break
        output_traces = filtered
        print(f"After experiment filter: {len(output_traces)} traces", file=sys.stderr)

    print("", file=sys.stderr)
    print(json.dumps({"traces": output_traces}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
