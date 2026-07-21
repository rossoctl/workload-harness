#!/bin/bash
# Deploy benchmark, agent, and run evaluation in one command
# Usage: ./deploy-and-evaluate.sh --benchmark <name> --agent <name> [OPTIONS]
# Example: ./deploy-and-evaluate.sh --benchmark tau2 --agent tool_calling
# Example: ./deploy-and-evaluate.sh --benchmark tau2 --agent tool_calling --model openai/Azure/gpt-4o-mini
# Example: ./deploy-and-evaluate.sh --benchmark tau2 --agent tool_calling --openshift apps.mycluster.example.com

set -e

# Report which step failed, then exit. Used as `cmd || fail "..."`: the `||`
# suppresses set -e for cmd so this message actually prints. A plain trailing
# `if [ $? -ne 0 ]` check is dead code under set -e — the script is killed on
# the failing line before the check ever runs.
fail() {
    echo ""
    echo "Error: $1"
    echo "STEP_FAILED: $1"
    exit 1
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables if .env exists (only vars not already in the environment)
if [ -f "$SCRIPT_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [ -z "${!key+x}" ]; then
            export "$key=$value"
        fi
    done < <(grep -v '^#' "$SCRIPT_DIR/.env" | grep -v '^$')
fi

# Default values (env vars from .env take precedence, CLI args override both)
BENCHMARK_NAME=""
AGENT_NAME=""
EXPERIMENT_NAME="default"
MODEL_NAME="openai/Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-unknown}"
MLFLOW_ENABLED="true"
MAX_TASKS="${MAX_TASKS:-1}"
MAX_PARALLEL_SESSIONS="${MAX_PARALLEL_SESSIONS:-1}"
USE_MCP_GATEWAY="${USE_MCP_GATEWAY:-false}"
USE_LOCAL_IMAGE="false"
DRY_RUN="false"
CLUSTER_MODE=""
INGRESS_DOMAIN=""

# AuthBridge plugin pipeline flags forwarded to deploy-agent.sh.
# See AUTHBRIDGE_PIPELINE_SPEC.md for the resolver semantics.
PIPELINE_PRESET=""
PIPELINE_SELECTORS=()
PIPELINE_OVERLAY_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --benchmark)
            BENCHMARK_NAME="$2"
            shift 2
            ;;
        --agent)
            AGENT_NAME="$2"
            shift 2
            ;;
        --experiment)
            EXPERIMENT_NAME="$2"
            shift 2
            ;;
        --model)
            MODEL_NAME="$2"
            shift 2
            ;;
        --keycloak-user)
            KEYCLOAK_USERNAME="$2"
            shift 2
            ;;
        --keycloak-pass)
            KEYCLOAK_PASSWORD="$2"
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
        --disable-mlflow)
            MLFLOW_ENABLED="false"
            shift
            ;;
        --use-mcp-gateway)
            USE_MCP_GATEWAY="true"
            shift
            ;;
        --local-image)
            USE_LOCAL_IMAGE="true"
            shift
            ;;
        --dry)
            DRY_RUN="true"
            shift
            ;;
        --plugin)
            PIPELINE_SELECTORS+=("--plugin" "$2")
            shift 2
            ;;
        --no-plugin)
            PIPELINE_SELECTORS+=("--no-plugin" "$2")
            shift 2
            ;;
        --plugin-preset)
            PIPELINE_PRESET="$2"
            shift 2
            ;;
        --plugin-config-file)
            PIPELINE_OVERLAY_FILE="$2"
            shift 2
            ;;
        --kind)
            CLUSTER_MODE="kind"
            shift
            ;;
        --openshift)
            CLUSTER_MODE="openshift"
            INGRESS_DOMAIN="$2"
            shift 2
            ;;
        --in-cluster)
            CLUSTER_MODE="in-cluster"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --benchmark <name> --agent <name> [OPTIONS]"
            echo ""
            echo "Required Arguments:"
            echo "  --benchmark NAME           Benchmark name (e.g., gsm8k, tau2)"
            echo "  --agent NAME               Agent name (e.g., tool_calling)"
            echo ""
            echo "Optional Arguments:"
            echo "  --experiment NAME          Experiment name for grouping/filtering runs (default: default)"
            echo "  --model MODEL              Model name (default: openai/Azure/gpt-4.1)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (default: admin)"
            echo "  --max-tasks N              Maximum number of tasks to evaluate (default: 1)"
            echo "  --max-parallel-sessions N  Number of concurrent evaluation sessions (default: 1)"
            echo "  --disable-mlflow           Disable MLflow tracing via OTEL collector during evaluation (default: enabled)"
            echo "  --use-mcp-gateway          Route MCP traffic through the MCP Gateway"
            echo "  --local-image              Use locally built images instead of pulling from registry"
            echo "  --dry                      Dry run mode - print commands without executing them"
            echo "  --kind                     Target a local Kind cluster (default)"
            echo "  --openshift DOMAIN         Target an OpenShift cluster with the given ingress domain"
            echo "  --in-cluster               Running as a Kubernetes Job inside the cluster"
            echo ""
            echo "AuthBridge plugin pipeline (see AUTHBRIDGE_PIPELINE_SPEC.md):"
            echo "  --plugin-preset PRESET     Named bundle: auth-only | ibac-only | full"
            echo "  --plugin NAME[:POLICY]     Enable plugin; POLICY ∈ {enforce(default), observe, off}; repeatable"
            echo "  --no-plugin NAME           Shorthand for --plugin NAME:off; repeatable"
            echo "  --plugin-config-file PATH  Flat-map YAML overlay merged after selectors"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark tau2 --agent tool_calling"
            echo "  $0 --benchmark tau2 --agent tool_calling --experiment baseline"
            echo "  $0 --benchmark tau2 --agent tool_calling --model openai/Azure/gpt-4o-mini"
            echo "  $0 --benchmark gsm8k --agent tool_calling --model openai/Azure/gpt-4o"
            echo "  $0 --benchmark gsm8k --agent tool_calling --experiment test1"
            echo "  $0 --benchmark tau2 --agent tool_calling --use-mcp-gateway"
            echo ""
            echo "This script will:"
            echo "  1. Deploy the benchmark using deploy-benchmark.sh"
            echo "  2. Deploy the agent using deploy-agent.sh"
            echo "  3. Run evaluation using evaluate_benchmark.sh"
            echo ""
            echo "Environment Variables:"
            echo "  USE_MCP_GATEWAY=true       Same as --use-mcp-gateway (set in .env)"
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$BENCHMARK_NAME" ]; then
    echo "Error: --benchmark is required"
    echo "Use -h or --help for usage information"
    exit 1
fi

if [ -z "$AGENT_NAME" ]; then
    echo "Error: --agent is required"
    echo "Use -h or --help for usage information"
    exit 1
fi

echo "=========================================="
echo "Deploy and Evaluate Exgentic Benchmark"
echo "=========================================="
echo "Benchmark: $BENCHMARK_NAME"
echo "Agent: $AGENT_NAME"
echo "Model: $MODEL_NAME"
echo "Max Tasks: $MAX_TASKS"
echo "Max Parallel Sessions: $MAX_PARALLEL_SESSIONS"
echo "Keycloak User: $KEYCLOAK_USERNAME"
echo "MLflow tracing: $MLFLOW_ENABLED"
echo "MCP Gateway: $USE_MCP_GATEWAY"
echo "Dry run: $DRY_RUN"
if [ -n "$PIPELINE_PRESET" ] || [ ${#PIPELINE_SELECTORS[@]} -gt 0 ] || [ -n "$PIPELINE_OVERLAY_FILE" ]; then
    echo "Plugin preset: ${PIPELINE_PRESET:-<none>}"
    echo "Plugin selectors: ${PIPELINE_SELECTORS[*]:-<none>}"
    [ -n "$PIPELINE_OVERLAY_FILE" ] && echo "Plugin overlay file: $PIPELINE_OVERLAY_FILE"
else
    echo "AuthBridge: disabled (no plugin selectors)"
fi
echo ""

# Build cluster-mode flag for sub-scripts
CLUSTER_FLAG=()
case "$CLUSTER_MODE" in
    kind)       CLUSTER_FLAG=(--kind) ;;
    openshift)  CLUSTER_FLAG=(--openshift "$INGRESS_DOMAIN") ;;
    in-cluster) CLUSTER_FLAG=(--in-cluster) ;;
    "")         ;;  # not set; sub-scripts will apply their own default
    *)
        echo "Error: unknown --cluster-mode '${CLUSTER_MODE}'. Use --kind, --openshift DOMAIN, or --in-cluster."
        exit 1
        ;;
esac

# Build gateway and local-image flags for sub-scripts
MCP_GATEWAY_FLAG=""
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    MCP_GATEWAY_FLAG="--use-mcp-gateway"
fi

LOCAL_IMAGE_FLAG=""
if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    LOCAL_IMAGE_FLAG="--local-image"
fi

# Build the plugin-flag passthrough array for deploy-agent.sh.
PLUGIN_FLAGS=()
if [ -n "$PIPELINE_PRESET" ]; then
    PLUGIN_FLAGS+=("--plugin-preset" "$PIPELINE_PRESET")
fi
if [ ${#PIPELINE_SELECTORS[@]} -gt 0 ]; then
    PLUGIN_FLAGS+=("${PIPELINE_SELECTORS[@]}")
fi
if [ -n "$PIPELINE_OVERLAY_FILE" ]; then
    PLUGIN_FLAGS+=("--plugin-config-file" "$PIPELINE_OVERLAY_FILE")
fi

# Step 1: Deploy benchmark
echo "=========================================="
echo "Step 1/3: Deploying Benchmark"
echo "=========================================="

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would execute:"
    BENCHMARK_CMD_DISPLAY=$(printf '%q ' \
        "$SCRIPT_DIR/deploy-benchmark.sh" \
        --benchmark "$BENCHMARK_NAME" \
        --experiment "$EXPERIMENT_NAME" \
        --model "$MODEL_NAME" \
        --keycloak-user "$KEYCLOAK_USERNAME" \
        --keycloak-pass "$KEYCLOAK_PASSWORD" \
        "${CLUSTER_FLAG[@]}")
    [ -n "$MCP_GATEWAY_FLAG" ] && BENCHMARK_CMD_DISPLAY="$BENCHMARK_CMD_DISPLAY$(printf '%q ' "$MCP_GATEWAY_FLAG")"
    [ -n "$LOCAL_IMAGE_FLAG" ] && BENCHMARK_CMD_DISPLAY="$BENCHMARK_CMD_DISPLAY$(printf '%q ' "$LOCAL_IMAGE_FLAG")"
    echo "$BENCHMARK_CMD_DISPLAY"
    echo ""
else
    "$SCRIPT_DIR/deploy-benchmark.sh" --benchmark "$BENCHMARK_NAME" \
        --experiment "$EXPERIMENT_NAME" \
        --model "$MODEL_NAME" \
        --keycloak-user "$KEYCLOAK_USERNAME" \
        --keycloak-pass "$KEYCLOAK_PASSWORD" \
        "${CLUSTER_FLAG[@]}" \
        $MCP_GATEWAY_FLAG \
        $LOCAL_IMAGE_FLAG \
        || fail "Benchmark deployment failed (step 1/3)"

    echo ""
    echo "✓ Benchmark deployed successfully"
    echo ""
fi

# Step 2: Deploy agent
echo "=========================================="
echo "Step 2/3: Deploying Agent"
echo "=========================================="

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would execute:"
    AGENT_CMD_DISPLAY=$(printf '%q ' \
        "$SCRIPT_DIR/deploy-agent.sh" \
        --benchmark "$BENCHMARK_NAME" \
        --agent "$AGENT_NAME" \
        --experiment "$EXPERIMENT_NAME" \
        --model "$MODEL_NAME" \
        --keycloak-user "$KEYCLOAK_USERNAME" \
        --keycloak-pass "$KEYCLOAK_PASSWORD" \
        "${CLUSTER_FLAG[@]}")
    [ -n "$MCP_GATEWAY_FLAG" ] && AGENT_CMD_DISPLAY="$AGENT_CMD_DISPLAY$(printf '%q ' "$MCP_GATEWAY_FLAG")"
    [ -n "$LOCAL_IMAGE_FLAG" ] && AGENT_CMD_DISPLAY="$AGENT_CMD_DISPLAY$(printf '%q ' "$LOCAL_IMAGE_FLAG")"
    if [ ${#PLUGIN_FLAGS[@]} -gt 0 ]; then
        AGENT_CMD_DISPLAY="$AGENT_CMD_DISPLAY$(printf '%q ' "${PLUGIN_FLAGS[@]}")"
    fi
    echo "$AGENT_CMD_DISPLAY"
    echo ""
else
    "$SCRIPT_DIR/deploy-agent.sh" --benchmark "$BENCHMARK_NAME" --agent "$AGENT_NAME" \
        --experiment "$EXPERIMENT_NAME" \
        --model "$MODEL_NAME" \
        --keycloak-user "$KEYCLOAK_USERNAME" \
        --keycloak-pass "$KEYCLOAK_PASSWORD" \
        "${CLUSTER_FLAG[@]}" \
        $MCP_GATEWAY_FLAG \
        $LOCAL_IMAGE_FLAG \
        "${PLUGIN_FLAGS[@]}" \
        || fail "Agent deployment failed (step 2/3)"

    echo ""
    echo "✓ Agent deployed successfully"
    echo ""
fi

# Step 3: Run evaluation
echo "=========================================="
echo "Step 3/3: Running Evaluation"
echo "=========================================="

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] Would execute:"
    EVALUATE_CMD_DISPLAY=$(printf '%q ' \
        "$SCRIPT_DIR/evaluate-benchmark.sh" \
        --benchmark "$BENCHMARK_NAME" \
        --agent "$AGENT_NAME" \
        --experiment "$EXPERIMENT_NAME" \
        --max-tasks "$MAX_TASKS" \
        --max-parallel-sessions "$MAX_PARALLEL_SESSIONS" \
        "${CLUSTER_FLAG[@]}")
    if [ "$MLFLOW_ENABLED" = "false" ]; then
        EVALUATE_CMD_DISPLAY="$EVALUATE_CMD_DISPLAY$(printf '%q ' --disable-mlflow)"
    fi
    if [ "$USE_MCP_GATEWAY" = "true" ]; then
        EVALUATE_CMD_DISPLAY="$EVALUATE_CMD_DISPLAY$(printf '%q ' --use-mcp-gateway)"
    fi
    echo "$EVALUATE_CMD_DISPLAY"
    echo ""
else
    EVALUATE_ARGS=(--benchmark "$BENCHMARK_NAME" --agent "$AGENT_NAME" --experiment "$EXPERIMENT_NAME")
    EVALUATE_ARGS+=(--max-tasks "$MAX_TASKS" --max-parallel-sessions "$MAX_PARALLEL_SESSIONS")
    if [ "$MLFLOW_ENABLED" = "false" ]; then
        EVALUATE_ARGS+=(--disable-mlflow)
    fi
    if [ "$USE_MCP_GATEWAY" = "true" ]; then
        EVALUATE_ARGS+=(--use-mcp-gateway)
    fi
    if [ ${#CLUSTER_FLAG[@]} -gt 0 ]; then
        EVALUATE_ARGS+=("${CLUSTER_FLAG[@]}")
    fi

    "$SCRIPT_DIR/evaluate-benchmark.sh" "${EVALUATE_ARGS[@]}" \
        || fail "Evaluation failed (step 3/3)"
fi

if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo "=========================================="
    echo "✓ Dry run completed - no commands executed"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "✓ All steps completed successfully!"
    echo "=========================================="
fi
echo "Benchmark: $BENCHMARK_NAME"
echo "Agent: $AGENT_NAME"
echo "Experiment: $EXPERIMENT_NAME"
echo "Model: $MODEL_NAME"
echo "=========================================="

