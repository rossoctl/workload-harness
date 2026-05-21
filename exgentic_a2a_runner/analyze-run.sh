#!/bin/bash

# analyze-run.sh - Download and analyze MLflow traces for Agent.Session spans
#
# Bash handles: connectivity, port-forwarding, OAuth token acquisition
# Python handles: downloading traces, format transformation, and analysis (analyze_traces.py)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default values
MLFLOW_URL=""
LIMIT=100
AUTO_PORT_FORWARD="false"
MLFLOW_NAMESPACE="kagenti-system"
MLFLOW_SERVICE="mlflow"
MLFLOW_LOCAL_PORT="8080"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
EXPERIMENT_ID="0"
EXPERIMENT_FILTER=""
COMPARE_EXPERIMENTS=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -u, --url URL              MLflow REST API base URL (default: http://mlflow.localtest.me:8080)
    -l, --limit NUM            Limit number of traces to download (default: 100)
    -e, --experiment NAME      Filter traces by experiment name attribute
    -c, --compare EXP1,EXP2    Compare two experiments (comma-separated)
    --experiment-id ID         MLflow experiment ID to query (default: 0)
    -f, --forward              Auto port-forward MLflow from kind cluster if not accessible
    -h, --help                 Show this help message

Examples:
    $0 -f -l 50
    $0 --experiment baseline
    $0 --compare baseline,test1
    $0 -u http://mlflow.localtest.me:8080 -l 200
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)           MLFLOW_URL="$2"; shift 2 ;;
        -l|--limit)         LIMIT="$2"; shift 2 ;;
        -e|--experiment)    EXPERIMENT_FILTER="$2"; shift 2 ;;
        -c|--compare)       COMPARE_EXPERIMENTS="$2"; shift 2 ;;
        --experiment-id)    EXPERIMENT_ID="$2"; shift 2 ;;
        -f|--forward)       AUTO_PORT_FORWARD="true"; shift ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

# Set default URL if not provided
if [ -z "$MLFLOW_URL" ]; then
    MLFLOW_URL="http://mlflow.localtest.me:8080"
fi

echo "=== MLflow Trace Analysis ==="
echo "MLflow URL: $MLFLOW_URL"
echo "Experiment ID: $EXPERIMENT_ID"
echo "Limit: $LIMIT"
if [ -n "$EXPERIMENT_FILTER" ]; then
    echo "Experiment Filter: $EXPERIMENT_FILTER"
fi
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    echo "Comparing Experiments: $COMPARE_EXPERIMENTS"
fi
echo ""

# --- Helper functions ---

OAUTH_TOKEN=""

get_oauth_token() {
    echo "Obtaining OAuth token from cluster..."

    local secret_json
    secret_json=$("$KUBECTL_BIN" get secret mlflow-oauth-secret -n "$MLFLOW_NAMESPACE" -o json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$secret_json" ]; then
        echo "Error: Could not read mlflow-oauth-secret from namespace $MLFLOW_NAMESPACE"
        return 1
    fi

    local client_id client_secret token_url
    client_id=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_ID"]' | base64 -d)
    client_secret=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_SECRET"]' | base64 -d)
    token_url=$(echo "$secret_json" | jq -r '.data["OIDC_TOKEN_URL"]' | base64 -d)

    if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$token_url" ]; then
        echo "Error: Could not extract OAuth credentials from secret"
        return 1
    fi

    local mlflow_pod
    mlflow_pod=$("$KUBECTL_BIN" get pod -n "$MLFLOW_NAMESPACE" -l app=mlflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$mlflow_pod" ]; then
        echo "Error: Could not find MLflow pod"
        return 1
    fi

    local token_response
    token_response=$("$KUBECTL_BIN" exec -n "$MLFLOW_NAMESPACE" "$mlflow_pod" -- \
        python3 -c "
import urllib.request, urllib.parse, json
data = urllib.parse.urlencode({
    'grant_type': 'client_credentials',
    'client_id': '${client_id}',
    'client_secret': '${client_secret}'
}).encode()
req = urllib.request.Request('${token_url}', data=data, headers={'Content-Type': 'application/x-www-form-urlencoded'})
resp = urllib.request.urlopen(req)
print(resp.read().decode())
" 2>/dev/null)

    OAUTH_TOKEN=$(echo "$token_response" | jq -r '.access_token' 2>/dev/null)
    if [ -z "$OAUTH_TOKEN" ] || [ "$OAUTH_TOKEN" = "null" ]; then
        echo "Error: Could not obtain OAuth token"
        echo "Response: $token_response"
        return 1
    fi

    echo "✓ OAuth token obtained"
}

setup_port_forward() {
    echo "Setting up port forwarding to MLflow in kind cluster..."

    if ! command -v "$KUBECTL_BIN" &> /dev/null; then
        echo "Error: $KUBECTL_BIN is not installed or not in PATH"; return 1
    fi
    if ! CURRENT_CONTEXT=$("$KUBECTL_BIN" config current-context 2>/dev/null); then
        echo "Error: Unable to determine current kubectl context"; return 1
    fi
    if [ "$CURRENT_CONTEXT" != "kind-kagenti" ]; then
        echo "Warning: Not connected to kind-kagenti cluster (current: $CURRENT_CONTEXT)"; return 1
    fi

    echo "Checking if MLflow pod is ready..."
    if ! "$KUBECTL_BIN" wait --for=condition=ready pod -l app=mlflow -n $MLFLOW_NAMESPACE --timeout=30s >/dev/null 2>&1; then
        echo "Error: MLflow pod is not ready in cluster"; return 1
    fi

    echo "Cleaning up existing port-forward on port ${MLFLOW_LOCAL_PORT}..."
    lsof -ti:${MLFLOW_LOCAL_PORT} | xargs kill -9 2>/dev/null || true
    sleep 2

    echo "Starting port-forward: localhost:${MLFLOW_LOCAL_PORT} -> ${MLFLOW_SERVICE}.${MLFLOW_NAMESPACE}:5000"
    "$KUBECTL_BIN" port-forward -n $MLFLOW_NAMESPACE svc/$MLFLOW_SERVICE ${MLFLOW_LOCAL_PORT}:5000 >/dev/null 2>&1 &
    PF_MLFLOW_PID=$!
    sleep 3

    if curl -s --max-time 2 -o /dev/null -w "%{http_code}" "${MLFLOW_URL}/health" 2>/dev/null | grep -q "200\|404"; then
        echo "✓ Port-forward established successfully"
    else
        echo "Warning: Port-forward started but MLflow may not be responding yet"
    fi
    return 0
}

cleanup_port_forward() {
    if [ -n "$PF_MLFLOW_PID" ]; then
        echo ""
        echo "Cleaning up port-forward (PID: $PF_MLFLOW_PID)..."
        kill $PF_MLFLOW_PID 2>/dev/null || true
    fi
}

# --- Step 1: Test connectivity / setup port-forward ---

echo "Connecting to MLflow..."
set +e
HEALTH_CHECK=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "${MLFLOW_URL}/health" 2>&1)
CURL_EXIT=$?
set -e

if [[ $CURL_EXIT -ne 0 ]] || [[ "$HEALTH_CHECK" == "000" ]]; then
    if [ "$AUTO_PORT_FORWARD" = "true" ]; then
        echo "MLflow not accessible locally, attempting to port-forward from kind cluster..."
        echo ""
        if setup_port_forward; then
            trap cleanup_port_forward EXIT
            echo ""
            echo "Retrying MLflow connection..."
            set +e
            HEALTH_CHECK=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "${MLFLOW_URL}/health" 2>&1)
            CURL_EXIT=$?
            set -e
            if [[ $CURL_EXIT -ne 0 ]] || [[ "$HEALTH_CHECK" == "000" ]]; then
                echo "Error: Still unable to connect to MLflow after port-forwarding"; exit 1
            fi
        else
            echo "Error: Failed to setup port-forward to MLflow"; exit 1
        fi
    else
        echo "Error: Failed to connect to MLflow at $MLFLOW_URL"
        echo "Use --forward flag to auto port-forward from kind cluster"
        exit 1
    fi
fi

echo "✓ Connected to MLflow"
echo ""

# --- Step 2: Obtain OAuth token ---

get_oauth_token
echo ""

# --- Step 3: Download traces, transform, and pipe to analyze_traces.py ---

export MLFLOW_URL OAUTH_TOKEN EXPERIMENT_ID LIMIT EXPERIMENT_FILTER COMPARE_EXPERIMENTS

PYTHON_ARGS=""
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    PYTHON_ARGS="--compare"
fi

python3 "$SCRIPT_DIR/download_mlflow_traces.py" | python3 "$SCRIPT_DIR/analyze_traces.py" $PYTHON_ARGS
