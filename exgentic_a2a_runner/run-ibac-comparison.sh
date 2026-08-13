#!/usr/bin/env bash
#
# Run a benchmark twice for comparison: once with a plugin preset and once
# without any plugins (baseline). Experiment names are derived from the
# parameters.
#
# Usage:
#   ./run-ibac-comparison.sh [OPTIONS]
#
# Options:
#   --model MODEL                  Model name (default: gcp/gemini-3-flash-preview)
#   --benchmark NAME               Benchmark name (default: gsm8k)
#   --agent NAME                   Agent name (default: tool_calling)
#   --max-tasks N                  Maximum number of tasks to evaluate (default: 10)
#   --max-parallel-sessions N      Number of concurrent evaluation sessions (default: 1)
#   --plugin-preset PRESET         Plugin preset for the first run:
#                                  auth-only | ibac-only | full (default: ibac-only)
#   --kind                         Target a local Kind cluster (default)
#   --openshift DOMAIN             Target an OpenShift cluster with the given ingress domain
#   --in-cluster                   Running as a Kubernetes Job inside the cluster
#   --save-analysis FILE           Save the computed analysis as JSON to FILE
#   --dry                          Dry run mode - print commands without executing them
#   -h, --help                     Show this help and exit
#
# The judge is configured from the OPENAI_API_BASE / OPENAI_API_KEY environment
# variables (as in the original template).
#
# Examples:
#   ./run-ibac-comparison.sh
#   ./run-ibac-comparison.sh --model gcp/gemini-3-flash-preview --benchmark gsm8k --max-tasks 10 --max-parallel-sessions 1
#   ./run-ibac-comparison.sh --plugin-preset full
#   ./run-ibac-comparison.sh --plugin-preset auth-only --benchmark gsm8k --openshift apps.mycluster.example.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (from the template)
MODEL="gcp/gemini-3-flash-preview"
BENCHMARK="gsm8k"
AGENT="tool_calling"
MAX_TASKS=10
MAX_PARALLEL_SESSIONS=1
PLUGIN_PRESET="ibac-only"
SAVE_ANALYSIS_FILE=""
DRY_RUN="false"

# Cluster-mode flag forwarded verbatim to deploy-and-evaluate.sh (which validates
# it). Empty means "unset" — the sub-scripts then apply their own default.
CLUSTER_FLAG=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --benchmark)
            BENCHMARK="$2"
            shift 2
            ;;
        --agent)
            AGENT="$2"
            shift 2
            ;;
        --max-tasks)
            MAX_TASKS="$2"
            shift 2
            ;;
        --max-parallel-sessions)
            MAX_PARALLEL_SESSIONS="$2"
            shift 2
            ;;
        --plugin-preset)
            PLUGIN_PRESET="$2"
            shift 2
            ;;
        --kind)
            CLUSTER_FLAG=(--kind)
            shift
            ;;
        --openshift)
            CLUSTER_FLAG=(--openshift "$2")
            shift 2
            ;;
        --in-cluster)
            CLUSTER_FLAG=(--in-cluster)
            shift
            ;;
        --save-analysis)
            SAVE_ANALYSIS_FILE="$2"
            shift 2
            ;;
        --dry)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Validate the plugin preset. deploy-and-evaluate.sh accepts only these values;
# passing anything else (e.g. "auth_only" with an underscore) produces a broken
# auth pipeline rather than a clear error, so reject it up front.
case "$PLUGIN_PRESET" in
    auth-only|ibac-only|sparc-only|full)
        ;;
    *)
        echo "Error: invalid --plugin-preset: '$PLUGIN_PRESET'" >&2
        echo "Valid values: auth-only | ibac-only | sparc-only| full" >&2
        exit 1
        ;;
esac

# A short random id keeps experiment names unique across repeated invocations
# with the same parameters (5 lowercase-alphanumeric chars).
#
# Read a fixed, bounded chunk from /dev/urandom BEFORE filtering: piping the
# unbounded stream straight into `head -c 5` makes `head` close the pipe early,
# which sends SIGPIPE to `tr` and — under `set -o pipefail` + `set -e` — kills
# the whole script intermittently. `head` on the source bounds the read so no
# writer is left with a closed pipe.
EXPERIMENT_ID="$(LC_ALL=C tr -dc 'a-z0-9' < <(head -c 256 /dev/urandom) | cut -c1-5)"

# Experiment names derived from the params. The plugin run is suffixed with the
# preset name (e.g. "-ibac" for ibac-only) to keep names meaningful per preset.
# The random id is appended so both runs in a comparison share the same id.
PRESET_SUFFIX="${PLUGIN_PRESET%-only}"
EXPERIMENT_BASE="${BENCHMARK}-${MAX_TASKS}-parallel-${MAX_PARALLEL_SESSIONS}-${EXPERIMENT_ID}"
EXPERIMENT_PLUGIN="${EXPERIMENT_BASE}-${PRESET_SUFFIX}"

# Judge configuration (from the template environment).
: "${OPENAI_API_BASE:?OPENAI_API_BASE must be set}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY must be set}"

echo "=========================================="
echo "Model:                  $MODEL"
echo "Benchmark:              $BENCHMARK"
echo "Agent:                  $AGENT"
echo "Max tasks:              $MAX_TASKS"
echo "Max parallel sessions:  $MAX_PARALLEL_SESSIONS"
echo "Plugin preset:          $PLUGIN_PRESET"
echo "Experiment id:          $EXPERIMENT_ID"
echo "Plugin experiment:      $EXPERIMENT_PLUGIN"
echo "Baseline experiment:    $EXPERIMENT_BASE"
if [ ${#CLUSTER_FLAG[@]} -gt 0 ]; then
    echo "Cluster mode:           ${CLUSTER_FLAG[*]}"
else
    echo "Cluster mode:           <default>"
fi
if [ -n "$SAVE_ANALYSIS_FILE" ]; then
    echo "Save analysis to:       $SAVE_ANALYSIS_FILE"
fi
echo "Dry run:                $DRY_RUN"
echo "=========================================="

# In dry-run mode, print each command instead of executing it, and forward
# --dry to deploy-and-evaluate.sh so its own steps are printed rather than run.
DRY_FLAG=()
if [ "$DRY_RUN" = "true" ]; then
    DRY_FLAG=(--dry)
fi

run_step() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] Would execute:"
        printf '%q ' "$@"
        echo ""
        echo ""
    else
        "$@"
    fi
}

# Run 1: with the selected plugin preset.
run_step "$SCRIPT_DIR/delete-all-deployments.sh" ${CLUSTER_FLAG[@]+"${CLUSTER_FLAG[@]}"}
run_step env IBAC_JUDGE_ENDPOINT="$OPENAI_API_BASE" \
    IBAC_JUDGE_MODEL="$MODEL" \
    JUDGE_BEARER="$OPENAI_API_KEY" \
    "$SCRIPT_DIR/deploy-and-evaluate.sh" \
        --benchmark "$BENCHMARK" \
        --agent "$AGENT" \
        --model "openai/$MODEL" \
        --max-tasks "$MAX_TASKS" \
        --max-parallel-sessions "$MAX_PARALLEL_SESSIONS" \
        --plugin-preset "$PLUGIN_PRESET" \
        --experiment "$EXPERIMENT_PLUGIN" \
        ${CLUSTER_FLAG[@]+"${CLUSTER_FLAG[@]}"} \
        ${DRY_FLAG[@]+"${DRY_FLAG[@]}"}

# Run 2: baseline (no plugin preset).
run_step "$SCRIPT_DIR/delete-all-deployments.sh" ${CLUSTER_FLAG[@]+"${CLUSTER_FLAG[@]}"}
run_step env IBAC_JUDGE_ENDPOINT="$OPENAI_API_BASE" \
    IBAC_JUDGE_MODEL="$MODEL" \
    JUDGE_BEARER="$OPENAI_API_KEY" \
    "$SCRIPT_DIR/deploy-and-evaluate.sh" \
        --benchmark "$BENCHMARK" \
        --agent "$AGENT" \
        --model "openai/$MODEL" \
        --max-tasks "$MAX_TASKS" \
        --max-parallel-sessions "$MAX_PARALLEL_SESSIONS" \
        --experiment "$EXPERIMENT_BASE" \
        ${CLUSTER_FLAG[@]+"${CLUSTER_FLAG[@]}"} \
        ${DRY_FLAG[@]+"${DRY_FLAG[@]}"}

# Compare the two runs.
ANALYZE_FLAGS=(-c "${EXPERIMENT_PLUGIN},${EXPERIMENT_BASE}")
if [ -n "$SAVE_ANALYSIS_FILE" ]; then
    ANALYZE_FLAGS+=(--save-analysis "$SAVE_ANALYSIS_FILE")
fi
run_step "$SCRIPT_DIR/analyze-run.sh" "${ANALYZE_FLAGS[@]}" ${CLUSTER_FLAG[@]+"${CLUSTER_FLAG[@]}"}

if [ "$DRY_RUN" = "true" ]; then
    echo "=========================================="
    echo "✓ Dry run completed - no commands executed"
    echo "=========================================="
fi
