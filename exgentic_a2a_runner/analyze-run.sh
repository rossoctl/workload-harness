#!/bin/bash

# analyze-run.sh - Download and analyze MLflow traces for Agent.Session spans
#
# Bash handles: connectivity, port-forwarding, OAuth token acquisition
# Python handles: downloading traces, format transformation, and analysis (analyze_traces.py)
#
# MLflow access mirrors how evaluate-benchmark.sh reaches the OTEL collector:
# by default we kubectl port-forward svc/mlflow:5000 -> localhost:$MLFLOW_LOCAL_PORT
# for both --kind and --openshift, then talk to http://localhost:$MLFLOW_LOCAL_PORT.
# Pass -u/--url to skip the port-forward and hit a reachable MLflow URL directly.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default values
MLFLOW_URL=""
# Time window to fetch, e.g. 3h / 90m / 2d. Only traces newer than this are
# downloaded. Replaces the old trace-count limit.
WINDOW="${WINDOW:-3h}"
# MLflow location, TLS, workspace, and auth mode all default based on the
# cluster mode (--kind vs --openshift) — see the mode dispatch below. These
# start empty so we can tell "user/env supplied a value" from "apply the
# per-mode default". An env var of the same name still pre-seeds the value and
# takes precedence over the mode default; an explicit CLI flag overrides both.
MLFLOW_NAMESPACE="${MLFLOW_NAMESPACE:-}"
MLFLOW_SERVICE="${MLFLOW_SERVICE:-}"
MLFLOW_REMOTE_PORT="${MLFLOW_REMOTE_PORT:-}"
MLFLOW_LOCAL_PORT="${MLFLOW_LOCAL_PORT:-8080}"
MLFLOW_TLS="${MLFLOW_TLS:-}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-}"
AUTH_MODE="${AUTH_MODE:-}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
# `whoami -t` is an OpenShift (oc) extension, not a kubectl subcommand, so the
# token command is separate from KUBECTL_BIN. Override with OC_BIN if needed.
OC_BIN="${OC_BIN:-oc}"
# Experiment ID also defaults per cluster mode (see the mode dispatch below):
# kind uses 0 (the Default experiment); OpenShift uses 1, since id 0 does not
# exist on RHOAI. Starts empty so we can tell "user set it" from "use default".
EXPERIMENT_ID="${EXPERIMENT_ID:-}"
EXPERIMENT_FILTER=""
COMPARE_EXPERIMENTS=""
CLUSTER_MODE=""
INGRESS_DOMAIN=""

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -u, --url URL              MLflow REST API base URL. If omitted, port-forward svc/mlflow from the cluster.
    -w, --window DURATION      Fetch traces from the last DURATION, e.g. 3h, 90m, 2d (default: 3h)
    -e, --experiment NAME      Filter traces by experiment name attribute
    -c, --compare EXP1,EXP2    Compare two experiments (comma-separated)
    --experiment-id ID         MLflow experiment ID to query (default: per cluster mode, see below)
    --kind                     Target a local Kind cluster (default)
    --openshift DOMAIN         Target an OpenShift cluster with the given ingress domain
    --mlflow-namespace NS      Namespace of the MLflow service
    --mlflow-service NAME      Name of the MLflow service
    --mlflow-port PORT         Remote MLflow service port to forward
    --mlflow-tls               MLflow serves HTTPS on the forwarded port
    --mlflow-workspace NAME    Send x-mlflow-workspace header
    --auth-mode MODE           Token source: secret (rossoctl oauth secret) or oc-token (oc whoami -t)
    -h, --help                 Show this help message

The MLflow location, TLS, workspace, auth mode, and experiment id all DEFAULT
from the cluster mode, so a plain --kind or --openshift needs no other flags:

                     --kind                    --openshift
    namespace        rossoctl-system            redhat-ods-applications
    service          mlflow                    mlflow
    remote port      5000                      8443
    tls              off (http)                on (https)
    workspace        (none)                    team1
    auth mode        secret                    oc-token
    experiment id    0                         1

Any of the above flags (or the matching env var) overrides its per-mode
default; env vars are also honored over the default. By default (no -u/--url)
the script port-forwards the MLflow service to localhost:${MLFLOW_LOCAL_PORT} for both
modes, matching how evaluate-benchmark.sh reaches the OTEL collector.

Examples:
    $0 --window 1h
    $0 --experiment baseline
    $0 --compare baseline,test1
    $0 --kind --window 6h
    $0 --openshift apps.mycluster.example.com
    $0 --openshift apps.mycluster.example.com --experiment-id 3 --compare baseline,test1
    $0 -u http://mlflow.localtest.me:8080 --window 2d
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)           MLFLOW_URL="$2"; shift 2 ;;
        -w|--window)        WINDOW="$2"; shift 2 ;;
        -e|--experiment)    EXPERIMENT_FILTER="$2"; shift 2 ;;
        -c|--compare)       COMPARE_EXPERIMENTS="$2"; shift 2 ;;
        --experiment-id)    EXPERIMENT_ID="$2"; shift 2 ;;
        --mlflow-namespace) MLFLOW_NAMESPACE="$2"; shift 2 ;;
        --mlflow-service)   MLFLOW_SERVICE="$2"; shift 2 ;;
        --mlflow-port)      MLFLOW_REMOTE_PORT="$2"; shift 2 ;;
        --mlflow-tls)       MLFLOW_TLS="true"; shift ;;
        --mlflow-workspace) MLFLOW_WORKSPACE="$2"; shift 2 ;;
        --auth-mode)        AUTH_MODE="$2"; shift 2 ;;
        --kind)             CLUSTER_MODE="kind"; shift ;;
        --openshift)
            CLUSTER_MODE="openshift"
            if [ $# -lt 2 ]; then
                echo "Error: --openshift requires an ingress domain argument"
                usage
            fi
            INGRESS_DOMAIN="$2"
            shift 2
            ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

# Default to kind when no cluster mode is given
if [ -z "$CLUSTER_MODE" ]; then
    CLUSTER_MODE="kind"
fi

# Validate cluster mode and its arguments, and fill in per-mode MLflow defaults.
# Every assignment uses ${VAR:-default} so an env var or explicit CLI flag that
# already set the value wins; only unset values fall back to the mode default.
case "$CLUSTER_MODE" in
    kind)
        # rossoctl's kind MLflow: HTTP on port 5000 in rossoctl-system, no
        # workspace header, client-credentials secret flow for auth.
        MLFLOW_NAMESPACE="${MLFLOW_NAMESPACE:-rossoctl-system}"
        MLFLOW_SERVICE="${MLFLOW_SERVICE:-mlflow}"
        MLFLOW_REMOTE_PORT="${MLFLOW_REMOTE_PORT:-5000}"
        MLFLOW_TLS="${MLFLOW_TLS:-false}"
        # MLFLOW_WORKSPACE left empty: kind MLflow needs no workspace header.
        AUTH_MODE="${AUTH_MODE:-secret}"
        EXPERIMENT_ID="${EXPERIMENT_ID:-0}"
        ;;
    openshift)
        if [ -z "$INGRESS_DOMAIN" ]; then
            echo "Error: --openshift requires an ingress domain argument"
            usage
        fi
        # RHOAI-managed MLflow: HTTPS on port 8443 in redhat-ods-applications,
        # behind an oauth-proxy that accepts the logged-in user token, and it
        # requires an x-mlflow-workspace header (team1).
        MLFLOW_NAMESPACE="${MLFLOW_NAMESPACE:-redhat-ods-applications}"
        MLFLOW_SERVICE="${MLFLOW_SERVICE:-mlflow}"
        MLFLOW_REMOTE_PORT="${MLFLOW_REMOTE_PORT:-8443}"
        MLFLOW_TLS="${MLFLOW_TLS:-true}"
        MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-team1}"
        AUTH_MODE="${AUTH_MODE:-oc-token}"
        # Experiment 0 does not exist on RHOAI; default to the lowest real id.
        EXPERIMENT_ID="${EXPERIMENT_ID:-1}"
        ;;
    *)
        echo "Error: unsupported cluster mode '${CLUSTER_MODE}'. Use --kind or --openshift DOMAIN."
        exit 1
        ;;
esac

case "$AUTH_MODE" in
    secret|oc-token) ;;
    *)
        echo "Error: unsupported --auth-mode '${AUTH_MODE}'. Use secret or oc-token."
        exit 1
        ;;
esac

# Decide how to reach MLflow. An explicit -u/--url is used as-is and skips the
# port-forward; otherwise we port-forward svc/mlflow and talk to it on localhost
# (same approach evaluate-benchmark.sh uses for the OTEL collector).
USE_PORT_FORWARD="false"
if [ -z "$MLFLOW_URL" ]; then
    USE_PORT_FORWARD="true"
    if [ "$MLFLOW_TLS" = "true" ]; then
        MLFLOW_URL="https://localhost:${MLFLOW_LOCAL_PORT}"
    else
        MLFLOW_URL="http://localhost:${MLFLOW_LOCAL_PORT}"
    fi
fi

# Parse the time window (e.g. 3h, 90m, 2d, or a bare number = hours) into
# milliseconds for the Python downloader.
parse_window_ms() {
    local w="$1" num unit
    if [[ "$w" =~ ^([0-9]+)([hmd]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]:-h}"
        case "$unit" in
            h) echo $(( num * 3600 * 1000 )) ;;
            m) echo $(( num * 60 * 1000 )) ;;
            d) echo $(( num * 86400 * 1000 )) ;;
        esac
        return 0
    fi
    return 1
}

if ! WINDOW_MS=$(parse_window_ms "$WINDOW"); then
    echo "Error: invalid --window '$WINDOW'. Use e.g. 3h, 90m, 2d."
    exit 1
fi

echo "=== MLflow Trace Analysis ==="
echo "Cluster mode: $CLUSTER_MODE"
if [ "$USE_PORT_FORWARD" = "true" ]; then
    echo "MLflow URL: $MLFLOW_URL (via port-forward svc/${MLFLOW_SERVICE})"
else
    echo "MLflow URL: $MLFLOW_URL (direct)"
fi
echo "Experiment ID: $EXPERIMENT_ID"
echo "Auth mode: $AUTH_MODE"
if [ -n "$MLFLOW_WORKSPACE" ]; then
    echo "Workspace: $MLFLOW_WORKSPACE"
fi
echo "Window: $WINDOW"
if [ -n "$EXPERIMENT_FILTER" ]; then
    echo "Experiment Filter: $EXPERIMENT_FILTER"
fi
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    echo "Comparing Experiments: $COMPARE_EXPERIMENTS"
fi
echo ""

# --- Verify kubectl points at the cluster matching CLUSTER_MODE ---
# The port-forward and OAuth steps below read a secret, exec into the MLflow
# pod, and forward its service, so the active kubectl context must match the
# requested mode. Catching a mismatch here gives a clear error up front.
export CLUSTER_MODE INGRESS_DOMAIN KUBECTL_BIN
# shellcheck source=libsh/check-kubectl-context.sh
source "$SCRIPT_DIR/libsh/check-kubectl-context.sh"
check_kubectl_context
echo ""

# --- Helper functions ---

OAUTH_TOKEN=""
PF_MLFLOW_PID=""

# Port-forward the MLflow service (remote port $MLFLOW_REMOTE_PORT) to
# localhost:$MLFLOW_LOCAL_PORT. Mirrors the OTEL collector port-forward in
# evaluate-benchmark.sh; used for both kind and openshift when no explicit
# -u/--url was given.
setup_port_forward() {
    echo "Starting port-forward for MLflow (${MLFLOW_NAMESPACE}/svc/${MLFLOW_SERVICE}:${MLFLOW_REMOTE_PORT} -> localhost:${MLFLOW_LOCAL_PORT})..."

    echo "Checking if MLflow pod is ready..."
    if ! "$KUBECTL_BIN" wait --for=condition=ready pod -l app=mlflow -n "$MLFLOW_NAMESPACE" --timeout=30s >/dev/null 2>&1; then
        echo "Error: MLflow pod (label app=mlflow) is not ready in namespace $MLFLOW_NAMESPACE"
        return 1
    fi

    "$KUBECTL_BIN" port-forward -n "$MLFLOW_NAMESPACE" "svc/${MLFLOW_SERVICE}" "${MLFLOW_LOCAL_PORT}:${MLFLOW_REMOTE_PORT}" >/dev/null 2>&1 &
    PF_MLFLOW_PID=$!
    sleep 3

    if ! ps -p "$PF_MLFLOW_PID" > /dev/null; then
        echo "Error: MLflow port-forward failed to start"
        return 1
    fi

    echo "✓ MLflow port-forward established (PID: $PF_MLFLOW_PID)"
    return 0
}

cleanup_port_forward() {
    if [ -n "$PF_MLFLOW_PID" ]; then
        echo ""
        echo "Stopping MLflow port-forward (PID: $PF_MLFLOW_PID)..."
        kill "$PF_MLFLOW_PID" 2>/dev/null || true
    fi
}

# secret mode: rossoctl's client-credentials flow. Reads mlflow-oauth-secret and
# execs into the MLflow pod to exchange it for an access token.
get_token_from_secret() {
    echo "Obtaining OAuth token via mlflow-oauth-secret..."

    # Note: under `set -e`, a failing command substitution aborts the script
    # before the following `if` can run. Capture status explicitly so the
    # error message below actually prints instead of the script dying silently.
    local secret_json secret_status
    secret_json=$("$KUBECTL_BIN" get secret mlflow-oauth-secret -n "$MLFLOW_NAMESPACE" -o json 2>/dev/null) && secret_status=0 || secret_status=$?
    if [ "$secret_status" -ne 0 ] || [ -z "$secret_json" ]; then
        echo "Error: Could not read mlflow-oauth-secret from namespace $MLFLOW_NAMESPACE"
        echo "Hint: confirm the secret exists on the current cluster ($($KUBECTL_BIN config current-context 2>/dev/null))"
        return 1
    fi

    local client_id client_secret token_url
    client_id=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_ID"]' | base64 -d) || true
    client_secret=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_SECRET"]' | base64 -d) || true
    token_url=$(echo "$secret_json" | jq -r '.data["OIDC_TOKEN_URL"]' | base64 -d) || true

    if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$token_url" ]; then
        echo "Error: Could not extract OAuth credentials from secret"
        return 1
    fi

    local mlflow_pod
    mlflow_pod=$("$KUBECTL_BIN" get pod -n "$MLFLOW_NAMESPACE" -l app=mlflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
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
" 2>/dev/null) || true

    OAUTH_TOKEN=$(echo "$token_response" | jq -r '.access_token' 2>/dev/null) || true
    if [ -z "$OAUTH_TOKEN" ] || [ "$OAUTH_TOKEN" = "null" ]; then
        echo "Error: Could not obtain OAuth token"
        echo "Response: $token_response"
        return 1
    fi

    echo "✓ OAuth token obtained"
}

# oc-token mode: use the logged-in user token, which the RHOAI mlflow-oauth-proxy
# accepts as a bearer token (mirrors the collector's serviceaccount-token auth).
get_token_from_oc() {
    if ! command -v "$OC_BIN" >/dev/null 2>&1; then
        echo "Error: '$OC_BIN' not found; the oc-token auth mode needs the OpenShift CLI"
        echo "Hint: install oc, or set OC_BIN to its path"
        return 1
    fi
    echo "Obtaining bearer token via '$OC_BIN whoami -t'..."
    OAUTH_TOKEN=$("$OC_BIN" whoami -t 2>/dev/null) || true
    if [ -z "$OAUTH_TOKEN" ]; then
        echo "Error: Could not obtain a user token from '$OC_BIN whoami -t'"
        echo "Hint: log in first (e.g. 'oc login ...') so a bearer token is available"
        return 1
    fi
    echo "✓ Bearer token obtained"
}

# Dispatch token acquisition based on the resolved auth mode.
get_oauth_token() {
    case "$AUTH_MODE" in
        secret)   get_token_from_secret ;;
        oc-token) get_token_from_oc ;;
        *)        echo "Error: unsupported auth mode '$AUTH_MODE'"; return 1 ;;
    esac
}

# --- Step 1: Port-forward (if needed) and test connectivity ---

if [ "$USE_PORT_FORWARD" = "true" ]; then
    if ! setup_port_forward; then
        echo "Error: Failed to set up MLflow port-forward"
        exit 1
    fi
    trap cleanup_port_forward EXIT
    echo ""
fi

# A reencrypt/self-signed TLS endpoint on localhost won't pass cert
# verification, so allow insecure TLS for the health check when --mlflow-tls
# is set. (This only affects the bash health probe; the Python downloader has
# its own connection handling — see note below.)
CURL_TLS_OPTS=()
if [ "$MLFLOW_TLS" = "true" ]; then
    CURL_TLS_OPTS=(-k)
fi

echo "Connecting to MLflow..."
set +e
HEALTH_CHECK=$(curl -s "${CURL_TLS_OPTS[@]}" --max-time 5 -o /dev/null -w "%{http_code}" "${MLFLOW_URL}/health" 2>&1)
CURL_EXIT=$?
set -e

if [[ $CURL_EXIT -ne 0 ]] || [[ "$HEALTH_CHECK" == "000" ]]; then
    echo "Error: Failed to connect to MLflow at $MLFLOW_URL"
    if [ "$USE_PORT_FORWARD" = "true" ]; then
        echo "The port-forward to svc/${MLFLOW_SERVICE} started but MLflow is not responding."
    else
        echo "Check that the URL passed via -u/--url points to a reachable MLflow instance."
    fi
    exit 1
fi

echo "✓ Connected to MLflow"
echo ""

# --- Step 2: Obtain OAuth token ---

if ! get_oauth_token; then
    echo "Error: Failed to obtain OAuth token; cannot download traces"
    exit 1
fi
echo ""

# --- Step 3: Download traces, transform, and pipe to analyze_traces.py ---

# MLFLOW_WORKSPACE: sent as the x-mlflow-workspace header (required by RHOAI).
# MLFLOW_INSECURE_TLS: skip cert verification for the port-forwarded HTTPS
# endpoint (reencrypt cert won't validate against localhost).
MLFLOW_INSECURE_TLS="false"
if [ "$MLFLOW_TLS" = "true" ]; then
    MLFLOW_INSECURE_TLS="true"
fi
export MLFLOW_URL OAUTH_TOKEN EXPERIMENT_ID WINDOW_MS EXPERIMENT_FILTER COMPARE_EXPERIMENTS
export MLFLOW_WORKSPACE MLFLOW_INSECURE_TLS

PYTHON_ARGS=""
if [ -n "$COMPARE_EXPERIMENTS" ]; then
    PYTHON_ARGS="--compare"
fi

python3 "$SCRIPT_DIR/download_mlflow_traces.py" | python3 "$SCRIPT_DIR/analyze_traces.py" $PYTHON_ARGS
