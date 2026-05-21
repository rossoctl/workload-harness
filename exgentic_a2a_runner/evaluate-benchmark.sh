#!/bin/bash
# Evaluate a specific Exgentic benchmark
# Usage: ./evaluate-benchmark.sh --benchmark <name> --agent <name> [--mlflow] [--use-mcp-gateway]
# Example: ./evaluate-benchmark.sh --benchmark tau2 --agent tool_calling
# Example: ./evaluate-benchmark.sh --benchmark tau2 --agent tool_calling --use-mcp-gateway

set -e

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

BENCHMARK_NAME=""
AGENT_NAME=""
EXPERIMENT_NAME="default"
MLFLOW_ENABLED="false"
OTEL_COLLECTOR_NAMESPACE="kagenti-system"
OTEL_COLLECTOR_SERVICE="otel-collector"
OTEL_COLLECTOR_LOCAL_PORT="4327"

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
        --mlflow)
            MLFLOW_ENABLED="true"
            shift
            ;;
        --use-mcp-gateway)
            USE_MCP_GATEWAY="true"
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
            echo "  --mlflow                   Enable MLflow tracing via OTEL collector (default: disabled)"
            echo "  --use-mcp-gateway          Route MCP traffic through the MCP Gateway"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark tau2 --agent tool_calling"
            echo "  $0 --benchmark gsm8k --agent generic_agent --experiment baseline"
            echo "  $0 --benchmark gsm8k --agent tool_calling --mlflow --experiment test1"
            echo "  $0 --benchmark tau2 --agent tool_calling --use-mcp-gateway"
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
    echo "Usage: $0 --benchmark <name> --agent <name> [--mlflow] [--use-mcp-gateway]"
    echo "Use --help for more information"
    exit 1
fi

# Load environment variables if .env exists (before setting service names)
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
fi

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
export BENCHMARK_SERVICE="exgentic-mcp-${BENCHMARK_NAME}-mcp"

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
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "MCP via Gateway: $MCP_GATEWAY_SERVICE.$MCP_GATEWAY_NAMESPACE:$MCP_GATEWAY_PORT"
else
    echo "Benchmark Service: $BENCHMARK_SERVICE"
fi
echo "MLflow tracing: ${MLFLOW_ENABLED}"
echo ""

# Check if kubectl is available
if ! command -v "$KUBECTL_BIN" &> /dev/null; then
    echo "Error: $KUBECTL_BIN is not installed or not in PATH"
    exit 1
fi

# Check if we're connected to a reachable cluster
if ! CURRENT_CONTEXT=$("$KUBECTL_BIN" config current-context 2>/dev/null); then
    echo "Error: Unable to determine current kubectl context"
    exit 1
fi
echo "Current kubectl context: $CURRENT_CONTEXT"

if ! "$KUBECTL_BIN" cluster-info >/dev/null 2>&1; then
    echo "Error: kubectl context '$CURRENT_CONTEXT' is not reachable"
    echo "Hint: refresh your cluster access or set KUBECTL_BIN to another kubectl wrapper"
    exit 1
fi

if [ "$CURRENT_CONTEXT" != "kind-kagenti" ]; then
    echo "Warning: Not connected to kind-kagenti cluster"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "Setting up port forwarding..."
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "  - MCP Gateway: localhost:7770 -> $MCP_GATEWAY_SERVICE.$MCP_GATEWAY_NAMESPACE:$MCP_GATEWAY_PORT"
else
    echo "  - MCP Server: localhost:7770 -> $BENCHMARK_SERVICE.team1:8000"
fi
echo "  - A2A Agent:  localhost:7701 -> $AGENT_SERVICE.team1:8080"
if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo "  - OTEL Collector: localhost:${OTEL_COLLECTOR_LOCAL_PORT} -> ${OTEL_COLLECTOR_SERVICE}.${OTEL_COLLECTOR_NAMESPACE}:4317"
fi
echo ""

# Kill any existing port-forwards on these ports
PORTS_TO_CLEANUP="7770 7701"
if [ "$MLFLOW_ENABLED" = "true" ]; then
    PORTS_TO_CLEANUP="$PORTS_TO_CLEANUP ${OTEL_COLLECTOR_LOCAL_PORT}"
fi

echo "Cleaning up existing port-forwards on ports:${PORTS_TO_CLEANUP}"
for PORT in $PORTS_TO_CLEANUP; do
    lsof -ti:$PORT | xargs kill -9 2>/dev/null || true
done
sleep 2

# Check if pods are ready before port-forwarding
echo "Checking if pods are ready..."

# Extract deployment names (remove -mcp suffix from BENCHMARK_SERVICE if present)
BENCHMARK_DEPLOYMENT="${BENCHMARK_SERVICE%-mcp}"
AGENT_DEPLOYMENT="$AGENT_SERVICE"

if [ "$USE_MCP_GATEWAY" = "true" ]; then
    # Check gateway pods
    echo "  Checking MCP Gateway pods..."
    "$KUBECTL_BIN" wait --for=condition=ready pod -l "service.istio.io/canonical-name=$MCP_GATEWAY_SERVICE" -n $MCP_GATEWAY_NAMESPACE --timeout=60s
    if [ $? -ne 0 ]; then
        echo "Error: MCP Gateway pod is not ready"
        exit 1
    fi
else
    # Wait for MCP server pod to be ready
    echo "  Checking MCP server pod..."
    "$KUBECTL_BIN" wait --for=condition=ready pod -l app.kubernetes.io/name=$BENCHMARK_DEPLOYMENT -n team1 --timeout=60s
    if [ $? -ne 0 ]; then
        echo "Error: MCP server pod is not ready"
        exit 1
    fi
fi

# Wait for agent pod to be ready
echo "  Checking agent pod..."
"$KUBECTL_BIN" wait --for=condition=ready pod -l app.kubernetes.io/name=$AGENT_DEPLOYMENT -n team1 --timeout=60s
if [ $? -ne 0 ]; then
    echo "Error: Agent pod is not ready"
    exit 1
fi

echo "✓ All pods are ready"
echo ""

if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo "  Checking OTEL collector pod..."
    "$KUBECTL_BIN" wait --for=condition=ready pod -l app=otel-collector -n $OTEL_COLLECTOR_NAMESPACE --timeout=60s
    if [ $? -ne 0 ]; then
        echo "Error: OTEL collector pod is not ready"
        exit 1
    fi
    echo "✓ OTEL collector pod is ready"
    echo ""
fi

# Additional wait to ensure services are fully started
echo "Waiting for services to be fully started..."
sleep 10

# Start port forwarding in background (suppress "Handling connection" messages)
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "Starting port-forward for MCP Gateway..."
    "$KUBECTL_BIN" port-forward -n $MCP_GATEWAY_NAMESPACE svc/$MCP_GATEWAY_SERVICE 7770:$MCP_GATEWAY_PORT >/dev/null 2>&1 &
else
    echo "Starting port-forward for MCP server..."
    "$KUBECTL_BIN" port-forward -n team1 svc/$BENCHMARK_SERVICE 7770:8000 >/dev/null 2>&1 &
fi
PF_MCP_PID=$!

echo "Starting port-forward for A2A agent..."
"$KUBECTL_BIN" port-forward -n team1 svc/$AGENT_SERVICE 7701:8080 >/dev/null 2>&1 &
PF_AGENT_PID=$!

if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo "Starting port-forward for OTEL collector (traces -> MLflow)..."
    "$KUBECTL_BIN" port-forward -n $OTEL_COLLECTOR_NAMESPACE svc/$OTEL_COLLECTOR_SERVICE ${OTEL_COLLECTOR_LOCAL_PORT}:4317 >/dev/null 2>&1 &
    PF_OTEL_COLLECTOR_PID=$!
fi

# Prometheus port-forward for infra metrics
PROMETHEUS_LOCAL_PORT="9191"
PROMETHEUS_NAMESPACE="istio-system"
PROMETHEUS_SERVICE="prometheus"

echo "Starting port-forward for Prometheus..."
"$KUBECTL_BIN" port-forward -n $PROMETHEUS_NAMESPACE svc/$PROMETHEUS_SERVICE ${PROMETHEUS_LOCAL_PORT}:9090 >/dev/null 2>&1 &
PF_PROMETHEUS_PID=$!

# Wait for port forwards to be ready
echo "Waiting for port forwards to be ready..."
sleep 5

# Check if port forwards are working
if ! ps -p $PF_MCP_PID > /dev/null; then
    echo "Error: MCP port-forward failed to start"
    exit 1
fi

if ! ps -p $PF_AGENT_PID > /dev/null; then
    echo "Error: Agent port-forward failed to start"
    kill $PF_MCP_PID 2>/dev/null || true
    exit 1
fi

if [ "$MLFLOW_ENABLED" = "true" ] && ! ps -p $PF_OTEL_COLLECTOR_PID > /dev/null; then
    echo "Error: OTEL collector port-forward failed to start"
    kill $PF_MCP_PID 2>/dev/null || true
    kill $PF_AGENT_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "✓ Port forwarding established"
echo "  MCP Server PID: $PF_MCP_PID"
echo "  A2A Agent PID:  $PF_AGENT_PID"
if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo "  OTEL Collector PID: $PF_OTEL_COLLECTOR_PID"
fi
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up port forwards..."
    kill $PF_MCP_PID 2>/dev/null || true
    kill $PF_AGENT_PID 2>/dev/null || true
    if [ "$MLFLOW_ENABLED" = "true" ]; then
        kill $PF_OTEL_COLLECTOR_PID 2>/dev/null || true
    fi
    kill $PF_PROMETHEUS_PID 2>/dev/null || true
    echo "Done."
}

trap cleanup EXIT INT TERM

# Test connectivity
echo "Testing connectivity..."
echo -n "  MCP Server: "
if curl -s -o /dev/null -w "%{http_code}" http://localhost:7770/health 2>/dev/null | grep -q "200\|404"; then
    echo "✓ Reachable"
else
    echo "✗ MCP Server not reachable at localhost:7770"
    exit 1
fi

echo -n "  A2A Agent:  "
if curl -s -o /dev/null -w "%{http_code}" http://localhost:7701/.well-known/agent-card.json 2>/dev/null | grep -q "200\|404"; then
    echo "✓ Reachable"
else
    echo "✗ A2A Agent not reachable at localhost:7701"
    exit 1
fi

if [ "$MLFLOW_ENABLED" = "true" ]; then
    echo -n "  OTEL Collector: "
    if nc -z localhost ${OTEL_COLLECTOR_LOCAL_PORT} 2>/dev/null; then
        echo "✓ Reachable"
    else
        echo "✗ OTEL Collector not reachable at localhost:${OTEL_COLLECTOR_LOCAL_PORT}"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "Starting Exgentic A2A Runner"
echo "=========================================="
echo ""

# Change to the script directory
cd "$(dirname "$0")"

# Check if virtual environment exists
if [ ! -d ".venv" ]; then
    echo "Virtual environment not found. Installing dependencies..."
    uv sync --python 3.12
fi

# Activate virtual environment and run
source .venv/bin/activate

# Load environment variables
if [ -f ".env" ]; then
    echo "Loading environment variables from .env"
    export $(cat .env | grep -v '^#' | xargs)
    echo ""
fi

# Set URLs for port-forwarded services (override .env if present)
export EXGENTIC_MCP_SERVER_URL="http://localhost:7770/mcp"
export A2A_BASE_URL="http://localhost:7701"

# Set tool prefix when using MCP gateway (gateway namespaces tools with a prefix)
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    export EXGENTIC_MCP_TOOL_PREFIX="${EXGENTIC_MCP_TOOL_PREFIX:-exgentic_${BENCHMARK_NAME}_}"
fi

# Export benchmark, agent, and experiment names for telemetry
export BENCHMARK_NAME="$BENCHMARK_NAME"
export AGENT_NAME="$AGENT_NAME"
export EXPERIMENT_NAME="$EXPERIMENT_NAME"

# Export Prometheus config for infra metrics collection
export PROMETHEUS_URL="http://localhost:${PROMETHEUS_LOCAL_PORT}"
export INFRA_MCP_POD_PREFIX="$BENCHMARK_DEPLOYMENT"
export INFRA_A2A_POD_PREFIX="$AGENT_DEPLOYMENT"
export INFRA_NAMESPACE="team1"

if [ "$MLFLOW_ENABLED" = "true" ]; then
    # Send OTEL traces to the collector, which forwards to MLflow's /v1/traces
    # with the required x-mlflow-experiment-id header and OAuth2 auth.
    # Traces land in MLflow experiment 0 (Default).
    export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:${OTEL_COLLECTOR_LOCAL_PORT}"
    export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
    export OTEL_EXPORTER_OTLP_INSECURE="true"
    echo "MLflow tracing enabled via OTEL collector (localhost:${OTEL_COLLECTOR_LOCAL_PORT} -> MLflow experiment 0)"
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