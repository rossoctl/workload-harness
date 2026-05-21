#!/bin/bash
# Deploy benchmark, agent, and run evaluation in one command
# Usage: ./deploy-and-evaluate.sh --benchmark <name> --agent <name> [OPTIONS]
# Example: ./deploy-and-evaluate.sh --benchmark tau2 --agent tool_calling
# Example: ./deploy-and-evaluate.sh --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables if .env exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Default values (env vars from .env take precedence, CLI args override both)
BENCHMARK_NAME=""
AGENT_NAME=""
EXPERIMENT_NAME="default"
MODEL_NAME="Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="unknown"
MLFLOW_ENABLED="false"
USE_MCP_GATEWAY="${USE_MCP_GATEWAY:-false}"

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
            echo "Optional Arguments:"
            echo "  --experiment NAME          Experiment name for grouping/filtering runs (default: default)"
            echo "  --model MODEL              Model name (default: Azure/gpt-4.1)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (default: admin)"
            echo "  --mlflow                   Enable MLflow tracing via OTEL collector during evaluation"
            echo "  --use-mcp-gateway          Route MCP traffic through the MCP Gateway"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark tau2 --agent tool_calling"
            echo "  $0 --benchmark tau2 --agent tool_calling --experiment baseline"
            echo "  $0 --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini"
            echo "  $0 --benchmark gsm8k --agent generic_agent --model Azure/gpt-4o"
            echo "  $0 --benchmark gsm8k --agent tool_calling --mlflow --experiment test1"
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
echo "Keycloak User: $KEYCLOAK_USERNAME"
echo "MLflow tracing: $MLFLOW_ENABLED"
echo "MCP Gateway: $USE_MCP_GATEWAY"
echo ""

# Build gateway flag for sub-scripts
MCP_GATEWAY_FLAG=""
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    MCP_GATEWAY_FLAG="--use-mcp-gateway"
fi

# Step 1: Deploy benchmark
echo "=========================================="
echo "Step 1/3: Deploying Benchmark"
echo "=========================================="
"$SCRIPT_DIR/deploy-benchmark.sh" --benchmark "$BENCHMARK_NAME" \
    --model "$MODEL_NAME" \
    --keycloak-user "$KEYCLOAK_USERNAME" \
    --keycloak-pass "$KEYCLOAK_PASSWORD" \
    $MCP_GATEWAY_FLAG

if [ $? -ne 0 ]; then
    echo "Error: Benchmark deployment failed"
    exit 1
fi

echo ""
echo "✓ Benchmark deployed successfully"
echo ""

# Step 2: Deploy agent
echo "=========================================="
echo "Step 2/3: Deploying Agent"
echo "=========================================="
"$SCRIPT_DIR/deploy-agent.sh" --benchmark "$BENCHMARK_NAME" --agent "$AGENT_NAME" \
    --model "$MODEL_NAME" \
    --keycloak-user "$KEYCLOAK_USERNAME" \
    --keycloak-pass "$KEYCLOAK_PASSWORD" \
    $MCP_GATEWAY_FLAG

if [ $? -ne 0 ]; then
    echo "Error: Agent deployment failed"
    exit 1
fi

echo ""
echo "✓ Agent deployed successfully"
echo ""

# Step 3: Run evaluation
echo "=========================================="
echo "Step 3/3: Running Evaluation"
echo "=========================================="
EVALUATE_ARGS=(--benchmark "$BENCHMARK_NAME" --agent "$AGENT_NAME" --experiment "$EXPERIMENT_NAME")
if [ "$MLFLOW_ENABLED" = "true" ]; then
    EVALUATE_ARGS+=(--mlflow)
fi
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    EVALUATE_ARGS+=(--use-mcp-gateway)
fi

"$SCRIPT_DIR/evaluate-benchmark.sh" "${EVALUATE_ARGS[@]}"

if [ $? -ne 0 ]; then
    echo "Error: Evaluation failed"
    exit 1
fi

echo ""
echo "=========================================="
echo "✓ All steps completed successfully!"
echo "=========================================="
echo "Benchmark: $BENCHMARK_NAME"
echo "Agent: $AGENT_NAME"
echo "Experiment: $EXPERIMENT_NAME"
echo "Model: $MODEL_NAME"
echo "=========================================="

