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
# Local port for the MLflow port-forward. Must NOT be 8080: the kind ingress
# serves keycloak.localtest.me (and other *.localtest.me hosts) on 8080, and
# keycloak.localtest.me resolves to 127.0.0.1 — so binding the port-forward to
# localhost:8080 would shadow Keycloak, and the secret-mode token request (a
# password grant against Keycloak) would hit MLflow instead.
MLFLOW_LOCAL_PORT="${MLFLOW_LOCAL_PORT:-8085}"
MLFLOW_TLS="${MLFLOW_TLS:-}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-}"
AUTH_MODE="${AUTH_MODE:-}"
# secret-mode (kind) auth: a password grant against the mlflow Keycloak client as
# an MLflow user. MLflow's mlflow-oidc-auth authorizes reads from its own user DB
# (where "admin" is seeded as a global admin), NOT from the token's Keycloak group
# claim — so the user must be one MLflow knows. Defaults to admin; override with
# MLFLOW_USER. The password defaults to the rossoctl-test-user secret in the
# keycloak namespace (which holds admin's password); override with KEYCLOAK_PASSWORD.
MLFLOW_USER="${MLFLOW_USER:-admin}"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-}"
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
# Directory to save the raw downloaded traces JSON into. Empty = don't save.
SAVE_TRACES_DIR="${SAVE_TRACES_DIR:-}"

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
    --save-traces DIR          Save the raw downloaded traces JSON into DIR (created if needed)
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
    $0 --window 6h --save-traces ./traces
EOF
    exit 1
}

# Capture the original invocation so the auth-failure hint can print the exact
# command to re-run (the arg loop below consumes "$@" via shift).
ORIGINAL_INVOCATION=("$0" "$@")

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
        --save-traces|-save-traces) SAVE_TRACES_DIR="$2"; shift 2 ;;
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

# If --save-traces was given, make sure the target directory exists (create it
# if needed) so the downloader's output can be written there.
if [ -n "$SAVE_TRACES_DIR" ]; then
    if ! mkdir -p "$SAVE_TRACES_DIR" 2>/dev/null; then
        echo "Error: could not create traces directory '$SAVE_TRACES_DIR'"
        exit 1
    fi
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
if [ -n "$SAVE_TRACES_DIR" ]; then
    echo "Saving traces to: $SAVE_TRACES_DIR"
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

# urls.sh provides keycloak_api_url (CLUSTER_MODE must be exported, done above);
# keycloak-direct-access.sh provides enable_direct_access_grants. Both are used
# by the secret-mode token flow (password grant against the mlflow client).
# shellcheck source=libsh/urls.sh
source "$SCRIPT_DIR/libsh/urls.sh"
# shellcheck source=libsh/keycloak-direct-access.sh
source "$SCRIPT_DIR/libsh/keycloak-direct-access.sh"

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

# secret mode: password (direct-access) grant against the mlflow Keycloak client.
#
# Why not client_credentials (the previous approach): that mints a token for the
# mlflow *service account*, which mlflow-oidc-auth does not grant experiment reads
# to, so the traces API returns 403. mlflow-oidc-auth authorizes from its own user
# DB, where "admin" is seeded as a global admin — so we obtain a token for a real
# MLflow user (default: admin) instead. The mlflow client already carries a groups
# protocol mapper and is the confidential client MLflow trusts.
#
# The client id/secret come from mlflow-oauth-secret; the user password defaults to
# the rossoctl-test-user secret (admin's password). The token endpoint is built from
# keycloak_api_url (the OIDC_TOKEN_URL in the secret points at the in-cluster
# Keycloak service, which is not reachable from the laptop).
get_token_from_secret() {
    echo "Obtaining OAuth token via password grant against the mlflow client..."

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

    local client_id client_secret
    client_id=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_ID"]' | base64 -d) || true
    client_secret=$(echo "$secret_json" | jq -r '.data["OIDC_CLIENT_SECRET"]' | base64 -d) || true
    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "Error: Could not extract OIDC client id/secret from mlflow-oauth-secret"
        return 1
    fi

    # Resolve the MLflow user's password: explicit KEYCLOAK_PASSWORD wins, else the
    # rossoctl-test-user secret (holds admin's password) in the keycloak namespace.
    local user_password="$KEYCLOAK_PASSWORD"
    if [ -z "$user_password" ]; then
        user_password=$("$KUBECTL_BIN" get secret rossoctl-test-user -n keycloak \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -z "$user_password" ]; then
        echo "Error: Could not resolve a password for MLflow user '$MLFLOW_USER'"
        echo "Hint: set KEYCLOAK_PASSWORD, or confirm the rossoctl-test-user secret exists in the keycloak namespace"
        return 1
    fi

    # The mlflow client needs Direct Access Grants enabled for the password grant.
    local KEYCLOAK_API
    KEYCLOAK_API="$(keycloak_api_url)"
    export KEYCLOAK_API
    enable_direct_access_grants "$client_id"

    local token_url="$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token"
    echo "Requesting token for user '$MLFLOW_USER' (client '$client_id')..."
    local token_response
    token_response=$(curl -s -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password" \
        -d "client_id=${client_id}" \
        -d "client_secret=${client_secret}" \
        -d "username=${MLFLOW_USER}" \
        -d "password=${user_password}" 2>/dev/null) || true

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

# download_mlflow_traces.py exits 75 when MLflow rejects the token (a valid
# token still gets 403 until the user has logged into the MLflow UI once, which
# is what populates mlflow-oidc-auth's permission DB). Capture the downloader's
# status via PIPESTATUS so we can print an actionable hint instead of a raw
# HTTP 403 traceback.
set +e
if [ -n "$SAVE_TRACES_DIR" ]; then
    # tee the downloader's stdout (the raw traces JSON) into a timestamped file
    # in SAVE_TRACES_DIR before it is piped to the analyzer, so both the saved
    # copy and the analysis come from the same download.
    SAVE_TRACES_FILE="$SAVE_TRACES_DIR/traces-$(date +%Y%m%d-%H%M%S).json"
    python3 "$SCRIPT_DIR/download_mlflow_traces.py" \
        | tee "$SAVE_TRACES_FILE" \
        | python3 "$SCRIPT_DIR/analyze_traces.py" $PYTHON_ARGS
    DOWNLOAD_STATUS=${PIPESTATUS[0]}
else
    python3 "$SCRIPT_DIR/download_mlflow_traces.py" | python3 "$SCRIPT_DIR/analyze_traces.py" $PYTHON_ARGS
    DOWNLOAD_STATUS=${PIPESTATUS[0]}
fi
set -e

if [ -n "$SAVE_TRACES_DIR" ] && [ "$DOWNLOAD_STATUS" -eq 0 ]; then
    echo ""
    echo "✓ Saved traces to $SAVE_TRACES_FILE"
fi

if [ "$DOWNLOAD_STATUS" -eq 75 ]; then
    echo ""
    echo "MLflow authentication succeeded but access was denied."
    echo "Log into the MLflow UI once (this registers your user with MLflow's"
    echo "permission system), then re-run the analysis:"
    echo ""
    printf '    '; printf '%q ' "${ORIGINAL_INVOCATION[@]}"; echo
    echo ""
    exit 75
fi

exit "$DOWNLOAD_STATUS"
