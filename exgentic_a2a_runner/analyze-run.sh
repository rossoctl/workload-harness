#!/bin/bash

# analyze-run.sh - Download and analyze Phoenix traces for Agent.Session spans
#
# Bash handles: connectivity, port-forwarding, GraphQL queries, downloading full traces
# Python handles: trace analysis and reporting (analyze_traces.py)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default values
PHOENIX_URL="http://phoenix.localtest.me:8080/graphql"
LIMIT=100
AUTO_PORT_FORWARD="false"
PHOENIX_NAMESPACE="kagenti-system"
PHOENIX_SERVICE="phoenix"
PHOENIX_HTTP_LOCAL_PORT="6006"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
PROJECT_NAME="default"
EXPERIMENT_FILTER=""
COMPARE_EXPERIMENTS=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -u, --url URL              Phoenix GraphQL endpoint URL (default: http://localhost:6006/graphql)
    -l, --limit NUM            Limit number of traces to download (default: 100)
    -p, --project NAME         Phoenix project name (default: default)
    -e, --experiment NAME      Filter traces by experiment name
    -c, --compare EXP1,EXP2    Compare two experiments (comma-separated)
    -f, --forward              Auto port-forward Phoenix from kind cluster if not accessible
    -h, --help                 Show this help message

Examples:
    $0 -u http://localhost:6006/graphql -l 200
    $0 -f -l 50
    $0 --experiment baseline
    $0 --compare baseline,test1
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)        PHOENIX_URL="$2"; shift 2 ;;
        -l|--limit)      LIMIT="$2"; shift 2 ;;
        -p|--project)    PROJECT_NAME="$2"; shift 2 ;;
        -e|--experiment) EXPERIMENT_FILTER="$2"; shift 2 ;;
        -c|--compare)    COMPARE_EXPERIMENTS="$2"; shift 2 ;;
        -f|--forward)    AUTO_PORT_FORWARD="true"; shift ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

echo "=== Phoenix Trace Analysis ==="
echo "Phoenix URL: $PHOENIX_URL"
echo "Project: $PROJECT_NAME"
echo "Limit: $LIMIT"
if [ -n "$EXPERIMENT_FILTER" ]; then
    echo "Experiment Filter: $EXPERIMENT_FILTER"
fi
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    echo "Comparing Experiments: $COMPARE_EXPERIMENTS"
fi
echo ""

# --- Helper functions ---

run_graphql() {
    local query="$1"
    curl -s --max-time 30 -X POST "$PHOENIX_URL" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"$query\"}" 2>&1
}

setup_port_forward() {
    echo "Setting up port forwarding to Phoenix in kind cluster..."

    if ! command -v "$KUBECTL_BIN" &> /dev/null; then
        echo "Error: $KUBECTL_BIN is not installed or not in PATH"; return 1
    fi
    if ! CURRENT_CONTEXT=$("$KUBECTL_BIN" config current-context 2>/dev/null); then
        echo "Error: Unable to determine current kubectl context"; return 1
    fi
    if [ "$CURRENT_CONTEXT" != "kind-kagenti" ]; then
        echo "Warning: Not connected to kind-kagenti cluster (current: $CURRENT_CONTEXT)"; return 1
    fi

    echo "Checking if Phoenix pod is ready..."
    if ! "$KUBECTL_BIN" wait --for=condition=ready pod -l app=phoenix -n $PHOENIX_NAMESPACE --timeout=30s >/dev/null 2>&1; then
        echo "Error: Phoenix pod is not ready in cluster"; return 1
    fi

    echo "Cleaning up existing port-forward on port ${PHOENIX_HTTP_LOCAL_PORT}..."
    lsof -ti:${PHOENIX_HTTP_LOCAL_PORT} | xargs kill -9 2>/dev/null || true
    sleep 2

    echo "Starting port-forward: localhost:${PHOENIX_HTTP_LOCAL_PORT} -> ${PHOENIX_SERVICE}.${PHOENIX_NAMESPACE}:6006"
    "$KUBECTL_BIN" port-forward -n $PHOENIX_NAMESPACE svc/$PHOENIX_SERVICE ${PHOENIX_HTTP_LOCAL_PORT}:6006 >/dev/null 2>&1 &
    PF_PHOENIX_PID=$!
    sleep 3

    if curl -s --max-time 2 "$PHOENIX_URL" -H "Content-Type: application/json" \
        -d '{"query":"{ __schema { queryType { name } } }"}' >/dev/null 2>&1; then
        echo "✓ Port-forward established successfully"
    else
        echo "Warning: Port-forward started but Phoenix is not responding yet"
    fi
    return 0
}

cleanup_port_forward() {
    if [ -n "$PF_PHOENIX_PID" ]; then
        echo ""
        echo "Cleaning up port-forward (PID: $PF_PHOENIX_PID)..."
        kill $PF_PHOENIX_PID 2>/dev/null || true
    fi
}

# --- Step 1: Test connectivity ---

echo "Connecting to Phoenix..."
set +e
RESPONSE=$(run_graphql "{ projects { edges { node { id name } } } }")
CURL_EXIT=$?
set -e

if [[ $CURL_EXIT -ne 0 ]] || [[ -z "$RESPONSE" ]] || echo "$RESPONSE" | grep -q "Connection refused\|Could not resolve\|Failed to connect" 2>/dev/null; then
    if [ "$AUTO_PORT_FORWARD" = "true" ]; then
        echo "Phoenix not accessible locally, attempting to port-forward from kind cluster..."
        echo ""
        if setup_port_forward; then
            trap cleanup_port_forward EXIT
            echo ""
            echo "Retrying Phoenix connection..."
            set +e
            RESPONSE=$(run_graphql "{ projects { edges { node { id name } } } }")
            CURL_EXIT=$?
            set -e
            if [[ $CURL_EXIT -ne 0 ]] || [[ -z "$RESPONSE" ]]; then
                echo "Error: Still unable to connect to Phoenix after port-forwarding"; exit 1
            fi
        else
            echo "Error: Failed to setup port-forward to Phoenix"; exit 1
        fi
    else
        echo "Error: Failed to connect to Phoenix at $PHOENIX_URL"
        echo "Use --forward flag to auto port-forward from kind cluster"
        exit 1
    fi
fi

# --- Step 2: Resolve project ID ---

PROJECT_ID=$(echo "$RESPONSE" | jq -r ".data.projects.edges[].node | select(.name == \"$PROJECT_NAME\") | .id" 2>/dev/null)

if [[ -z "$PROJECT_ID" ]] || [[ "$PROJECT_ID" == "null" ]]; then
    echo "Error: Project '$PROJECT_NAME' not found in Phoenix"
    echo "Available projects:"
    echo "$RESPONSE" | jq -r '.data.projects.edges[].node.name' 2>/dev/null
    exit 1
fi

echo "✓ Connected to Phoenix (project: $PROJECT_NAME, id: $PROJECT_ID)"
echo ""

# --- Step 3: Find Agent.Session root span trace IDs ---

echo "Fetching Agent.Session traces..."

# Build filter condition
FILTER_CONDITION="name == 'Agent.Session'"
if [ -n "$EXPERIMENT_FILTER" ]; then
    FILTER_CONDITION="$FILTER_CONDITION and metadata.experiment_name == '$EXPERIMENT_FILTER'"
fi
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    IFS=',' read -ra EXPERIMENTS <<< "$COMPARE_EXPERIMENTS"
    EXP_CONDITIONS=""
    for exp in "${EXPERIMENTS[@]}"; do
        if [ -z "$EXP_CONDITIONS" ]; then
            EXP_CONDITIONS="metadata.experiment_name == '$exp'"
        else
            EXP_CONDITIONS="$EXP_CONDITIONS or metadata.experiment_name == '$exp'"
        fi
    done
    FILTER_CONDITION="$FILTER_CONDITION and ($EXP_CONDITIONS)"
fi

ROOTS_QUERY="{ node(id: \\\"$PROJECT_ID\\\") { ... on Project { spans(first: $LIMIT, rootSpansOnly: true, sort: {col: startTime, dir: desc}, filterCondition: \\\"$FILTER_CONDITION\\\") { edges { node { context { traceId } } } } } } }"

set +e
ROOTS_RESPONSE=$(run_graphql "$ROOTS_QUERY")
set -e

if echo "$ROOTS_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Error: GraphQL query failed"
    echo "$ROOTS_RESPONSE" | jq '.errors'
    exit 1
fi

TRACE_IDS=$(echo "$ROOTS_RESPONSE" | jq -r '.data.node.spans.edges[].node.context.traceId' 2>/dev/null)

if [[ -z "$TRACE_IDS" ]]; then
    echo "No Agent.Session traces found"
    exit 0
fi

TRACE_COUNT=$(echo "$TRACE_IDS" | wc -l | tr -d ' ')
echo "Found $TRACE_COUNT Agent.Session traces"
echo "Downloading full traces with child spans..."

# --- Step 4: Download full traces (root + all children) ---

# Build a JSON array of traces, each with all their spans
TRACES_JSON="["
FIRST=true

for TRACE_ID in $TRACE_IDS; do
    TRACE_QUERY="{ node(id: \\\"$PROJECT_ID\\\") { ... on Project { trace(traceId: \\\"$TRACE_ID\\\") { traceId spans(first: 500) { edges { node { name spanKind statusCode statusMessage latencyMs startTime parentId context { traceId spanId } attributes } } } } } } }"

    set +e
    TRACE_RESPONSE=$(run_graphql "$TRACE_QUERY")
    set -e

    # Extract spans array
    SPANS=$(echo "$TRACE_RESPONSE" | jq -c '.data.node.trace.spans.edges[].node' 2>/dev/null)
    if [[ -z "$SPANS" ]]; then
        continue
    fi

    # Build spans array for this trace
    SPANS_ARRAY=$(echo "$TRACE_RESPONSE" | jq -c '[.data.node.trace.spans.edges[].node]' 2>/dev/null)

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        TRACES_JSON+=","
    fi
    TRACES_JSON+="{\"traceId\":\"$TRACE_ID\",\"spans\":$SPANS_ARRAY}"
done

TRACES_JSON+="]"

echo "Downloaded $TRACE_COUNT traces"
echo ""

# --- Step 5: Pipe to Python for analysis ---

PYTHON_ARGS=""
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    PYTHON_ARGS="--compare"
fi

echo "$TRACES_JSON" | jq -c '{traces: .}' | python3 "$SCRIPT_DIR/analyze_traces.py" $PYTHON_ARGS
