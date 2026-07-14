#!/bin/bash
# End-to-end test: deploy and evaluate the given agent against all benchmarks.
# Usage: ./e2e-test.sh --agent <name> [OPTIONS]
#
# Runs deploy-and-evaluate.sh for each benchmark (gsm8k -> tau2 -> appworld)
# and prints a consolidated results table when all benchmarks finish.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
AGENT_NAME=""
TASKS="1"
MAX_PARALLEL_SESSIONS=""
PARALLEL="false"
IN_CLUSTER="false"
DRY_RUN="false"
BENCHMARKS=(gsm8k tau2 appworld)
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: $0 --agent <name> [OPTIONS]

Required:
  --agent NAME           Agent name (e.g., tool_calling)

Options:
  --benchmarks LIST      Comma-separated benchmarks to run (default: gsm8k,tau2,appworld)
  --max-tasks N          Maximum number of tasks to evaluate (default: 1)
  --max-parallel-sessions N  Concurrent sessions per benchmark (default: 1)
  --parallel-jobs        Run all benchmarks concurrently; collect all results
  --in-cluster           Submit a Kubernetes Job per benchmark instead of running locally
  --dry                  Forward --dry to deploy-and-evaluate.sh (no commands executed)
  -h, --help             Show this help

Pass-through options (forwarded to deploy-and-evaluate.sh):
  Any unrecognised flags (e.g. --model, --experiment, --disable-mlflow) are
  forwarded verbatim to deploy-and-evaluate.sh.

Examples:
  $0 --agent tool_calling
  $0 --agent tool_calling --benchmarks gsm8k
  $0 --agent tool_calling --benchmarks gsm8k,tau2
  $0 --agent tool_calling --max-tasks 3
  $0 --agent tool_calling --parallel-jobs
  $0 --agent tool_calling --max-parallel-sessions 4
  $0 --agent tool_calling --in-cluster
  $0 --agent tool_calling --dry
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --agent)
            AGENT_NAME="$2"
            shift 2
            ;;
        --benchmarks)
            IFS=',' read -ra BENCHMARKS <<< "$2"
            shift 2
            ;;
        --max-tasks)
            TASKS="$2"
            shift 2
            ;;
        --max-parallel-sessions)
            MAX_PARALLEL_SESSIONS="$2"
            shift 2
            ;;
        --parallel-jobs)
            PARALLEL="true"
            shift
            ;;
        --in-cluster)
            IN_CLUSTER="true"
            shift
            ;;
        --dry)
            DRY_RUN="true"
            EXTRA_ARGS+=(--dry)
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ -z "$AGENT_NAME" ]; then
    echo "Error: --agent is required"
    usage
    exit 1
fi

TMPDIR_E2E="$(mktemp -d)"
cleanup_tmp() { rm -rf "$TMPDIR_E2E"; }
trap cleanup_tmp EXIT

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

# run_local BENCHMARK LOG_FILE
# Runs deploy-and-evaluate.sh for one benchmark; tees output to LOG_FILE.
run_local() {
    local benchmark="$1"
    local log="$2"
    local -a run_args=(--benchmark "$benchmark" --agent "$AGENT_NAME" --max-tasks "$TASKS")
    [ -n "$MAX_PARALLEL_SESSIONS" ] && run_args+=(--max-parallel-sessions "$MAX_PARALLEL_SESSIONS")
    "$SCRIPT_DIR/deploy-and-evaluate.sh" \
        "${run_args[@]}" \
        "${EXTRA_ARGS[@]}" \
        2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
}

# run_k8s BENCHMARK LOG_FILE
# Submits a Kubernetes Job for one benchmark and streams its logs.
run_k8s() {
    local benchmark="$1"
    local log="$2"
    local job_name="exgentic-runner-e2e-${benchmark}"
    local namespace="team1"
    local job_yaml="$TMPDIR_E2E/job-${benchmark}.yaml"

    # Build per-benchmark args
    local -a job_args=(--benchmark "$benchmark" --agent "$AGENT_NAME")
    for arg in "${EXTRA_ARGS[@]}"; do
        job_args+=("$arg")
    done

    # Build the args JSON array for the Job spec
    local args_json="["
    local first=true
    for a in "${job_args[@]}"; do
        if [ "$first" = "true" ]; then
            first=false
        else
            args_json+=","
        fi
        # Escape for JSON
        escaped=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
        args_json+="\"${escaped}\""
    done
    args_json+="]"

    # Source the template job.yaml and patch it
    if [ ! -f "$SCRIPT_DIR/k8s/job.yaml" ]; then
        echo "Error: k8s/job.yaml not found at $SCRIPT_DIR/k8s/job.yaml" >&2
        return 1
    fi

    # Rewrite job.yaml with a unique name, updated args, and MAX_TASKS / MAX_PARALLEL_SESSIONS env vars.
    python3 - "$SCRIPT_DIR/k8s/job.yaml" "$job_yaml" \
        "$job_name" "$args_json" "$TASKS" "${MAX_PARALLEL_SESSIONS:-}" <<'PYEOF'
import sys, yaml, json

src, dst, job_name, args_json, max_tasks, parallel_sessions = sys.argv[1:]

with open(src) as f:
    doc = yaml.safe_load(f)

doc["metadata"]["name"] = job_name
container = doc["spec"]["template"]["spec"]["containers"][0]
container["args"] = json.loads(args_json)

# Inject / update env vars
env = container.setdefault("env", [])
env = [e for e in env if e.get("name") not in ("MAX_TASKS", "MAX_PARALLEL_SESSIONS")]
env.append({"name": "MAX_TASKS", "value": str(max_tasks)})
if parallel_sessions:
    env.append({"name": "MAX_PARALLEL_SESSIONS", "value": str(parallel_sessions)})
container["env"] = env

with open(dst, "w") as f:
    yaml.dump(doc, f, default_flow_style=False)
PYEOF

    {
        if [ "$DRY_RUN" = "true" ]; then
            echo "[DRY RUN] Would apply k8s job:"
            cat "$job_yaml"
            echo ""
            echo "[DRY RUN] Would wait for job/$job_name in namespace $namespace"
            return 0
        fi

        echo "Submitting Job $job_name..."
        kubectl delete job "$job_name" -n "$namespace" --ignore-not-found >/dev/null 2>&1 || true
        kubectl apply -f "$job_yaml"

        echo "Waiting for Job $job_name to start..."
        # Wait up to 60s for a pod to appear
        local elapsed=0
        while [ $elapsed -lt 60 ]; do
            local pod
            pod=$(kubectl get pods -n "$namespace" \
                -l "job-name=$job_name" \
                --field-selector=status.phase!=Pending \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            if [ -n "$pod" ]; then
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done

        echo "Streaming logs for Job $job_name..."
        kubectl logs -f "job/$job_name" -n "$namespace" || true

        # Collect final job exit status
        local succeeded
        succeeded=$(kubectl get job "$job_name" -n "$namespace" \
            -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
        if [ "${succeeded}" != "1" ]; then
            echo "Job $job_name did not succeed" >&2
            return 1
        fi
    } 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
}

# run_benchmark BENCHMARK
# Dispatches to run_local or run_k8s; writes log to $TMPDIR_E2E/<benchmark>.log.
# Returns the exit code of the underlying run.
run_benchmark() {
    local benchmark="$1"
    local log="$TMPDIR_E2E/${benchmark}.log"
    if [ "$IN_CLUSTER" = "true" ]; then
        run_k8s "$benchmark" "$log"
    else
        run_local "$benchmark" "$log"
    fi
}

# parse_stats BENCHMARK
# Reads $TMPDIR_E2E/<benchmark>.log and emits tab-separated fields:
#   BENCHMARK STATUS TASKS MAX_PARALLEL_SESSIONS EVAL_SUCCESS_RATE AVG_LATENCY FAILURES
parse_stats() {
    local benchmark="$1"
    local log="$TMPDIR_E2E/${benchmark}.log"
    local exit_code_file="$TMPDIR_E2E/${benchmark}.exit"

    local exit_val="1"
    [ -f "$exit_code_file" ] && exit_val="$(cat "$exit_code_file")"

    local status="FAIL"
    if [ "$exit_val" = "0" ]; then
        status="PASS"
    elif [ "$exit_val" = "skipped" ]; then
        status="SKIP"
    fi

    local tasks_col="$TASKS"
    local parallel_sessions_col="${MAX_PARALLEL_SESSIONS:---}"
    local eval_rate="--"
    local avg_latency="--"
    local failures="--"

    if [ -f "$log" ]; then
        # Surface which step failed (sentinel emitted by deploy-and-evaluate.sh fail())
        if [ "$status" = "FAIL" ]; then
            local step_msg
            step_msg=$(grep -o 'STEP_FAILED:.*' "$log" 2>/dev/null | tail -1 | sed 's/STEP_FAILED: //' || true)
            [ -n "$step_msg" ] && status="FAIL(${step_msg})"
        fi

        local rate
        rate=$(grep -o 'Evaluation Success:[^%]*%' "$log" 2>/dev/null | tail -1 | grep -o '[0-9.]*%' || true)
        [ -n "$rate" ] && eval_rate="$rate"

        local lat
        lat=$(grep -o 'Average:[[:space:]]*[0-9.]*s' "$log" 2>/dev/null | tail -1 | grep -o '[0-9.]*' || true)
        [ -n "$lat" ] && avg_latency="${lat}s"

        local err
        err=$(grep -o 'Sessions With Error:[[:space:]]*[0-9]*' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*$' || true)
        [ -n "$err" ] && failures="$err"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$benchmark" "$status" "$tasks_col" "$parallel_sessions_col" \
        "$eval_rate" "$avg_latency" "$failures"
}

# print_table
# Reads per-benchmark stats and writes an ASCII table to stdout and e2e-results.md.
print_table() {
    # Collect all rows first so we can measure column widths.
    local -a rows=()
    for benchmark in "${BENCHMARKS[@]}"; do
        rows+=("$(parse_stats "$benchmark")")
    done

    # Compute column widths as max(header, data) for each column.
    local -a headers=("Benchmark" "Status" "Tasks" "Parallel Sessions" "Eval Success Rate" "Avg Latency (s)" "Failures")
    local -a widths=()
    for h in "${headers[@]}"; do
        widths+=("${#h}")
    done

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r b s t p e l f <<< "$row"
        local -a cells=("$b" "$s" "$t" "$p" "$e" "$l" "$f")
        for i in 0 1 2 3 4 5 6; do
            local w="${#cells[$i]}"
            [ "$w" -gt "${widths[$i]}" ] && widths[$i]="$w"
        done
    done

    # Build separator and header lines.
    dashes() { printf '%*s' "$1" '' | tr ' ' '-'; }

    local sep="|"
    for w in "${widths[@]}"; do
        sep+="$(dashes $((w + 2)))|"
    done

    local header="|"
    for i in 0 1 2 3 4 5 6; do
        header+=" $(printf '%-*s' "${widths[$i]}" "${headers[$i]}") |"
    done

    {
        echo "$header"
        echo "$sep"
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r b s t p e l f <<< "$row"
            local -a cells=("$b" "$s" "$t" "$p" "$e" "$l" "$f")
            local line="|"
            for i in 0 1 2 3 4 5 6; do
                line+=" $(printf '%-*s' "${widths[$i]}" "${cells[$i]}") |"
            done
            echo "$line"
        done
    } | tee e2e-results.md

    echo ""
    echo "Results written to e2e-results.md"
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

echo "=========================================="
echo "E2E Test: agent=$AGENT_NAME tasks=$TASKS${MAX_PARALLEL_SESSIONS:+ max-parallel-sessions=$MAX_PARALLEL_SESSIONS}"
echo "Mode: $([ "$IN_CLUSTER" = "true" ] && echo in-cluster || echo local) / $([ "$PARALLEL" = "true" ] && echo parallel-jobs || echo sequential)"
echo "=========================================="
echo ""

if [ "$PARALLEL" = "true" ]; then
    # Launch all benchmarks concurrently; store PID in a per-benchmark file.
    # Each benchmark gets unique local ports so parallel evaluate-benchmark.sh
    # instances don't collide on the same port-forward and kill each other's.
    local_idx=0
    for benchmark in "${BENCHMARKS[@]}"; do
        echo "Starting benchmark: $benchmark"
        (
            export OTEL_COLLECTOR_LOCAL_PORT=$((4327 + local_idx))
            export PROMETHEUS_LOCAL_PORT=$((9191 + local_idx))
            if run_benchmark "$benchmark"; then
                echo 0 > "$TMPDIR_E2E/${benchmark}.exit"
            else
                echo $? > "$TMPDIR_E2E/${benchmark}.exit"
                exit 1
            fi
        ) &
        echo $! > "$TMPDIR_E2E/${benchmark}.pid"
        local_idx=$((local_idx + 1))
    done

    # Wait for all and collect exit codes
    overall=0
    for benchmark in "${BENCHMARKS[@]}"; do
        pid="$(cat "$TMPDIR_E2E/${benchmark}.pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && wait "$pid"; then
            : # exit code written by subshell
        else
            echo 1 > "$TMPDIR_E2E/${benchmark}.exit"
            overall=1
        fi
        code="$(cat "$TMPDIR_E2E/${benchmark}.exit" 2>/dev/null || echo 1)"
        [ "$code" != "0" ] && overall=1
    done
else
    # Sequential: stop on first failure
    overall=0
    for benchmark in "${BENCHMARKS[@]}"; do
        echo "=========================================="
        echo "Running benchmark: $benchmark"
        echo "=========================================="
        if run_benchmark "$benchmark"; then
            echo 0 > "$TMPDIR_E2E/${benchmark}.exit"
        else
            echo 1 > "$TMPDIR_E2E/${benchmark}.exit"
            overall=1
            echo ""
            echo "Benchmark $benchmark failed — stopping."
            # Mark remaining benchmarks as skipped
            local_skipped=false
            for remaining in "${BENCHMARKS[@]}"; do
                if [ "$local_skipped" = "true" ]; then
                    echo "skipped" > "$TMPDIR_E2E/${remaining}.exit"
                fi
                [ "$remaining" = "$benchmark" ] && local_skipped=true
            done
            break
        fi
    done
fi

echo ""
echo "=========================================="
echo "Results"
echo "=========================================="
print_table

exit $overall
