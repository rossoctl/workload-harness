#!/bin/bash
# Evaluate a specific Exgentic benchmark
# Usage: ./evaluate-benchmark.sh --benchmark <name> --agent <name> [--disable-mlflow] [--use-mcp-gateway]
# Example: ./evaluate-benchmark.sh --benchmark tau2 --agent tool_calling
# Example: ./evaluate-benchmark.sh --benchmark tau2 --agent tool_calling --use-mcp-gateway

set -e

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

BENCHMARK_NAME=""
AGENT_NAME=""
EXPERIMENT_NAME="default"
MLFLOW_ENABLED="true"
OTEL_COLLECTOR_NAMESPACE="kagenti-system"
OTEL_COLLECTOR_SERVICE="otel-collector"
OTEL_COLLECTOR_LOCAL_PORT="${OTEL_COLLECTOR_LOCAL_PORT:-4327}"
CLUSTER_MODE=""
MAX_TASKS="${MAX_TASKS:-1}"
MAX_PARALLEL_SESSIONS="${MAX_PARALLEL_SESSIONS:-1}"

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
        --disable-mlflow)
            MLFLOW_ENABLED="false"
            shift
            ;;
        --use-mcp-gateway)
            USE_MCP_GATEWAY="true"
            shift
            ;;
        --max-tasks)
            MAX_TASKS="$2"
            shift 2
            ;;
        --max-parallel-sessions)
            MAX_PARALLEL_SESSIONS="$2"
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
            echo "  --agent NAME               Agent name (e.g., tool_calling, generic_agent)"
            echo ""
            echo "Options:"
            echo "  --experiment NAME          Experiment name for grouping/filtering runs (default: default)"
            echo "  --max-tasks N              Maximum number of tasks to evaluate (default: 1)"
            echo "  --max-parallel-sessions N  Number of concurrent evaluation sessions (default: 1)"
            echo "  --disable-mlflow           Disable MLflow tracing via OTEL collector (default: enabled)"
            echo "  --use-mcp-gateway          Route MCP traffic through the MCP Gateway"
            echo "  --kind                     Target a local Kind cluster (default)"
            echo "  --openshift DOMAIN         Target an OpenShift cluster with the given ingress domain"
            echo "  --in-cluster               Running as a Kubernetes Job inside the cluster"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark tau2 --agent tool_calling"
            echo "  $0 --benchmark gsm8k --agent generic_agent --experiment baseline"
            echo "  $0 --benchmark gsm8k --agent tool_calling --experiment test1"
            echo "  $0 --benchmark tau2 --agent tool_calling --use-mcp-gateway"
            echo "  $0 --benchmark tau2 --agent tool_calling --openshift apps.mycluster.example.com"
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ -z "$BENCHMARK_NAME" ] || [ -z "$AGENT_NAME" ]; then
    echo "Error: Both --benchmark and --agent are required"
    echo "Usage: $0 --benchmark <name> --agent <name> [--disable-mlflow] [--use-mcp-gateway]"
    echo "Use --help for more information"
    exit 1
fi

# Load environment variables if .env exists (before setting service names)
# Only set vars not already in the environment so CLI overrides are respected.
EVAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$EVAL_SCRIPT_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [ -z "${!key+x}" ]; then
            export "$key=$value"
        fi
    done < <(grep -v '^#' "$EVAL_SCRIPT_DIR/.env" | grep -v '^$')
fi

# Load shared URL helpers
export CLUSTER_MODE INGRESS_DOMAIN
# shellcheck source=libsh/urls.sh
source "$EVAL_SCRIPT_DIR/libsh/urls.sh"

# Construct agent service name
if [[ "$AGENT_NAME" == exgentic-a2a-* ]]; then
    FULL_AGENT_NAME="$AGENT_NAME"
else
    FULL_AGENT_NAME="exgentic-a2a-${AGENT_NAME}"
fi
# Replace underscores with hyphens for Kubernetes compatibility
export AGENT_SERVICE="${FULL_AGENT_NAME}-${BENCHMARK_NAME}"
AGENT_SERVICE="${AGENT_SERVICE//_/-}"

# Set benchmark service name (override .env values)
BENCHMARK_BASE="exgentic-mcp-${BENCHMARK_NAME}"

# Append experiment suffix when non-default so service names match the deployed pods
if [ -n "$EXPERIMENT_NAME" ] && [ "$EXPERIMENT_NAME" != "default" ]; then
    EXPERIMENT_SUFFIX="${EXPERIMENT_NAME//_/-}"
    AGENT_SERVICE="${AGENT_SERVICE}-${EXPERIMENT_SUFFIX}"
    BENCHMARK_BASE="${BENCHMARK_BASE}-${EXPERIMENT_SUFFIX}"
fi

export BENCHMARK_SERVICE="${BENCHMARK_BASE}-mcp"

# MCP Gateway configuration
USE_MCP_GATEWAY="${USE_MCP_GATEWAY:-false}"
MCP_GATEWAY_SERVICE="mcp-gateway-istio"
MCP_GATEWAY_NAMESPACE="gateway-system"
MCP_GATEWAY_PORT=8080

echo "=========================================="
echo "Exgentic A2A Runner - Benchmark Evaluation"
echo "=========================================="
echo "Benchmark: $BENCHMARK_NAME"
echo "Agent Service: $AGENT_SERVICE"
echo "Max Tasks: $MAX_TASKS"
echo "Max Parallel Sessions: $MAX_PARALLEL_SESSIONS"
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "MCP via Gateway: $MCP_GATEWAY_SERVICE.$MCP_GATEWAY_NAMESPACE:$MCP_GATEWAY_PORT"
else
    echo "Benchmark Service: $BENCHMARK_SERVICE"
fi
echo "MLflow tracing: ${MLFLOW_ENABLED}"
echo ""

# shellcheck source=libsh/check-kubectl-context.sh
source "$EVAL_SCRIPT_DIR/libsh/check-kubectl-context.sh"
check_kubectl_context

# Derive canonical service URLs using the shared helpers.
# Extract deployment names (remove -mcp suffix from BENCHMARK_SERVICE if present)
BENCHMARK_DEPLOYMENT="${BENCHMARK_SERVICE%-mcp}"
AGENT_DEPLOYMENT="$AGENT_SERVICE"

if [ "$USE_MCP_GATEWAY" = "true" ]; then
    MCP_BASE_URL="$(mcp_gateway_url)"
else
    MCP_BASE_URL="$(tool_http_url "$BENCHMARK_DEPLOYMENT" "${NAMESPACE:-team1}")"
fi
AGENT_BASE_URL="$(agent_http_url "$AGENT_SERVICE" "${NAMESPACE:-team1}")"

echo ""
echo "Using service endpoints..."
echo "  - MCP: $MCP_BASE_URL"
echo "  - A2A Agent: $AGENT_BASE_URL"
echo ""

# curl-based readiness retry: wait up to $2 seconds for $1 to return HTTP 2xx/404.
# 404 is accepted for health endpoints that may not exist on all servers.
# Use wait_for_url_strict for endpoints that must return 2xx (e.g. agent card).
wait_for_url() {
    local url="$1"
    local timeout="${2:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null) || true
        if echo "$code" | grep -qE "^(2[0-9]{2}|404)$"; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Like wait_for_url but only accepts 2xx — use for endpoints that must be serving.
wait_for_url_strict() {
    local url="$1"
    local timeout="${2:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null) || true
        if echo "$code" | grep -qE "^2[0-9]{2}$"; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

echo "Checking if services are ready..."

if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "  Checking MCP Gateway..."
    if ! wait_for_url "$MCP_BASE_URL/health" 60; then
        echo "Error: MCP Gateway not reachable at $MCP_BASE_URL after 60s"
        exit 1
    fi
else
    echo "  Checking MCP server..."
    if ! wait_for_url "$MCP_BASE_URL/health" 60; then
        echo "Error: MCP server not reachable at $MCP_BASE_URL after 60s"
        exit 1
    fi
fi

echo "  Checking A2A Agent..."
if ! wait_for_url_strict "$AGENT_BASE_URL/.well-known/agent-card.json" 60; then
    echo "Error: A2A Agent not reachable at $AGENT_BASE_URL after 60s"
    exit 1
fi

echo "✓ All services are ready"
echo ""

# Additional wait to ensure services are fully started
echo "Waiting for services to be fully started..."
sleep 5

# Port-forwarding is only available and needed on a developer laptop.
# Inside the cluster, use cluster-DNS URLs from libsh/urls.sh directly.
PF_OTEL_COLLECTOR_PID=""
PF_PROMETHEUS_PID=""

PROMETHEUS_LOCAL_PORT="${PROMETHEUS_LOCAL_PORT:-9191}"
PROMETHEUS_NAMESPACE="istio-system"
PROMETHEUS_SERVICE="prometheus"

if [ "$CLUSTER_MODE" != "in-cluster" ]; then
    if [ "$MLFLOW_ENABLED" = "true" ]; then
        echo "Starting port-forward for OTEL collector (traces -> MLflow)..."
        "$KUBECTL_BIN" port-forward -n $OTEL_COLLECTOR_NAMESPACE svc/$OTEL_COLLECTOR_SERVICE ${OTEL_COLLECTOR_LOCAL_PORT}:4317 >/dev/null 2>&1 &
        PF_OTEL_COLLECTOR_PID=$!
    fi

    echo "Starting port-forward for Prometheus..."
    "$KUBECTL_BIN" port-forward -n $PROMETHEUS_NAMESPACE svc/$PROMETHEUS_SERVICE ${PROMETHEUS_LOCAL_PORT}:9090 >/dev/null 2>&1 &
    PF_PROMETHEUS_PID=$!

    if [ "$MLFLOW_ENABLED" = "true" ]; then
        echo "Waiting for OTEL collector port-forward to be ready..."
        sleep 3

        if ! ps -p $PF_OTEL_COLLECTOR_PID > /dev/null; then
            echo "Error: OTEL collector port-forward failed to start"
            exit 1
        fi

        echo ""
        echo "✓ OTEL collector port-forward established"
        echo "  OTEL Collector PID: $PF_OTEL_COLLECTOR_PID"
        echo ""
    fi
else
    echo "Running in-cluster — using cluster DNS for Prometheus and OTEL, no port-forwards needed."
fi

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [ -n "$PF_OTEL_COLLECTOR_PID" ]; then
        echo "Stopping OTEL collector port-forward..."
        kill $PF_OTEL_COLLECTOR_PID 2>/dev/null || true
    fi
    if [ -n "$PF_PROMETHEUS_PID" ]; then
        echo "Stopping Prometheus port-forward..."
        kill $PF_PROMETHEUS_PID 2>/dev/null || true
    fi
    echo "Done."
}

trap cleanup EXIT INT TERM

# Test connectivity
echo "Testing connectivity..."

MCP_TEST_URL="$MCP_BASE_URL/health"
AGENT_TEST_URL="$AGENT_BASE_URL/.well-known/agent-card.json"

echo -n "  MCP Server: "
if curl -s -o /dev/null -w "%{http_code}" "$MCP_TEST_URL" 2>/dev/null | grep -q "200\|404"; then
    echo "✓ Reachable"
else
    echo "✗ MCP Server not reachable at $MCP_TEST_URL"
    exit 1
fi

echo -n "  A2A Agent:  "
if curl -s -o /dev/null -w "%{http_code}" "$AGENT_TEST_URL" 2>/dev/null | grep -q "200\|404"; then
    echo "✓ Reachable"
else
    echo "✗ A2A Agent not reachable at $AGENT_TEST_URL"
    exit 1
fi

if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo -n "  OTEL Collector: "
    OTEL_CHECK_URL="$(otel_collector_url)"
    if [ "$CLUSTER_MODE" = "in-cluster" ]; then
        if curl -s -o /dev/null --max-time 3 "$OTEL_CHECK_URL" 2>/dev/null; then
            echo "✓ Reachable"
        else
            echo "✗ OTEL Collector not reachable at $OTEL_CHECK_URL"
            echo "  MLflow tracing is enabled but the OTEL collector cannot be reached."
            echo "  Run with --disable-mlflow to skip tracing, or fix collector connectivity."
            exit 1
        fi
    else
        if nc -z localhost ${OTEL_COLLECTOR_LOCAL_PORT} 2>/dev/null; then
            echo "✓ Reachable"
        else
            echo "✗ OTEL Collector not reachable at localhost:${OTEL_COLLECTOR_LOCAL_PORT}"
            exit 1
        fi
    fi
fi

echo ""
echo "=========================================="
echo "Starting Exgentic A2A Runner"
echo "=========================================="
echo ""

# Change to the script directory
cd "$EVAL_SCRIPT_DIR"

# The container image pre-installs the venv at build time via `uv sync`.
# On a developer laptop the venv may not exist yet, so create it on demand.
if [ ! -d ".venv" ]; then
    echo "Virtual environment not found. Installing dependencies..."
    uv sync --python 3.12
fi

# Activate virtual environment and run
source .venv/bin/activate

# Set URLs for services (use shared helpers for local/in-cluster selection)
export EXGENTIC_MCP_SERVER_URL="${MCP_BASE_URL}/mcp"
export A2A_BASE_URL="$AGENT_BASE_URL"

# Set tool prefix when using MCP gateway (gateway namespaces tools with a prefix)
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    export EXGENTIC_MCP_TOOL_PREFIX="${EXGENTIC_MCP_TOOL_PREFIX:-exgentic_${BENCHMARK_NAME}_}"
fi

# Export benchmark, agent, and experiment names for telemetry
export BENCHMARK_NAME="$BENCHMARK_NAME"
export AGENT_NAME="$AGENT_NAME"
export EXPERIMENT_NAME="$EXPERIMENT_NAME"

# Export task/concurrency limits for the Python runner
export MAX_TASKS="$MAX_TASKS"
export MAX_PARALLEL_SESSIONS="$MAX_PARALLEL_SESSIONS"

# Export Prometheus config for infra metrics collection
export PROMETHEUS_URL="$(prometheus_url)"
export INFRA_MCP_POD_PREFIX="$BENCHMARK_DEPLOYMENT"
export INFRA_A2A_POD_PREFIX="$AGENT_DEPLOYMENT"
export INFRA_NAMESPACE="${NAMESPACE:-team1}"

if [ "$MLFLOW_ENABLED" = "true" ]; then
    # Send OTEL traces to the collector, which forwards to MLflow's /v1/traces
    # with the required x-mlflow-experiment-id header and OAuth2 auth.
    # Traces land in MLflow experiment 0 (Default).
    OTEL_ENDPOINT="$(otel_collector_url)"
    export OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_ENDPOINT"
    if [ "$CLUSTER_MODE" = "in-cluster" ]; then
        export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
    else
        export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
        export OTEL_EXPORTER_OTLP_INSECURE="true"
    fi
    echo "MLflow tracing enabled via OTEL collector ($OTEL_ENDPOINT)"
fi

# Run the harness with optional log level
LOG_LEVEL_ARG=""
if [ -n "${LOG_LEVEL}" ]; then
    LOG_LEVEL_ARG="--log-level ${LOG_LEVEL}"
    echo "Running: uv run exgentic-a2a-runner --log-level ${LOG_LEVEL}"
else
    echo "Running: uv run exgentic-a2a-runner"
fi
echo ""
uv run exgentic-a2a-runner $LOG_LEVEL_ARG

# Cleanup will happen automatically via trap

# Made with Bob