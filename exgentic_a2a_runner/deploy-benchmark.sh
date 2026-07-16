#!/bin/bash
# Deploy and Configure Exgentic benchmark to Kagenti cluster
# Usage: ./deploy-benchmark.sh --benchmark <name> [OPTIONS]
# Example: ./deploy-benchmark.sh --benchmark gsm8k
# Example: ./deploy-benchmark.sh --benchmark tau2 --model Azure/gpt-4o-mini
# Example: ./deploy-benchmark.sh --benchmark tau2 --openshift apps.mycluster.example.com

set -e

# Default values — env vars take precedence (allows injection via Kubernetes Job secrets)
MODEL_NAME="Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-unknown}"
BENCHMARK_NAME=""
USE_MCP_GATEWAY="false"
USE_LOCAL_IMAGE="false"
CLUSTER_MODE=""
ACTION_TIMEOUT="1000"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --benchmark)
            BENCHMARK_NAME="$2"
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
        --use-mcp-gateway)
            USE_MCP_GATEWAY="true"
            shift
            ;;
        --local-image)
            USE_LOCAL_IMAGE="true"
            shift
            ;;
        --action-timeout)
            ACTION_TIMEOUT="$2"
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
            echo "Usage: $0 --benchmark <name> [OPTIONS]"
            echo ""
            echo "Required Arguments:"
            echo "  --benchmark NAME           Benchmark name (e.g., gsm8k, tau2)"
            echo ""
            echo "Optional Arguments:"
            echo "  --model MODEL              Model name (default: Azure/gpt-4.1)"
            echo "  --action-timeout SECONDS   Per-action step timeout in seconds (default: 30)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (auto-detected from cluster if not provided)"
            echo "  --use-mcp-gateway          Register MCP server with the MCP Gateway"
            echo "  --local-image              Use locally built image instead of pulling from registry"
            echo "  --kind                     Target a local Kind cluster (default)"
            echo "  --openshift DOMAIN         Target an OpenShift cluster with the given ingress domain"
            echo "  --in-cluster               Running as a Kubernetes Job inside the cluster"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark gsm8k"
            echo "  $0 --benchmark tau2 --model Azure/gpt-4o-mini"
            echo "  $0 --benchmark tau2 --openshift apps.mycluster.example.com"
            echo "  $0 --benchmark tau2 --use-mcp-gateway"
            echo "  $0 --benchmark gsm8k --local-image"
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

if [ -z "$BENCHMARK_NAME" ]; then
    echo "Error: --benchmark is required"
    echo "Usage: $0 --benchmark <name> [OPTIONS]"
    echo "Use --help for more information"
    exit 1
fi

# Load shared URL helpers (kagenti_api_url, keycloak_api_url, tool_http_url, …)
SCRIPT_DIR_BENCH="$(cd "$(dirname "$0")" && pwd)"
export CLUSTER_MODE INGRESS_DOMAIN
# shellcheck source=libsh/urls.sh
source "$SCRIPT_DIR_BENCH/libsh/urls.sh"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
# shellcheck source=libsh/check-kubectl-context.sh
source "$SCRIPT_DIR_BENCH/libsh/check-kubectl-context.sh"
check_kubectl_context

# Default to Exgentic registry, can be overridden with environment variable
EXGENTIC_REGISTRY="${EXGENTIC_REGISTRY:-ghcr.io/exgentic}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REMOTE_IMAGE_NAME="${EXGENTIC_REGISTRY}/exgentic-mcp-${BENCHMARK_NAME}:${IMAGE_TAG}"
TOOL_NAME="exgentic-mcp-${BENCHMARK_NAME}"
NAMESPACE="team1"
KAGENTI_API="$(kagenti_api_url)"
KEYCLOAK_API="$(keycloak_api_url)"

echo "=========================================="
echo "Deploying Exgentic Benchmark: $BENCHMARK_NAME"
echo "=========================================="
echo "Model: $MODEL_NAME"
echo ""

# Step 1: Sync local image to cluster
if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    echo "Step 1: Syncing local image to cluster..."
    export REMOTE_IMAGE_NAME KIND_CLUSTER_NAME="kagenti"
    source "$(dirname "$0")/sync-image-to-cluster.sh"
else
    echo "Step 1: Syncing local image to cluster... (skipped, K8s will pull from remote registry)"
fi

IMAGE_NAME="$REMOTE_IMAGE_NAME"
echo ""

# Step 3: Verify Keycloak is accessible
echo "Step 3: Verifying Keycloak is accessible at $KEYCLOAK_API..."
KEYCLOAK_REACHABLE=false
for i in $(seq 1 10); do
    if curl -s --max-time 5 "$KEYCLOAK_API/health" >/dev/null 2>&1; then
        echo "✓ Keycloak is accessible"
        KEYCLOAK_REACHABLE=true
        break
    fi
    sleep 1
done

if [ "$KEYCLOAK_REACHABLE" = false ]; then
    echo "Error: Keycloak is not accessible at $KEYCLOAK_API after 10s"
    echo "Please ensure Keycloak is running and reachable via HTTP route"
    exit 1
fi

echo ""

# Step 3.5: Auto-fetch Keycloak password from cluster if using default (without testing yet)
if [ "$KEYCLOAK_PASSWORD" = "unknown" ]; then
    echo "Step 3.5: Fetching Keycloak password from cluster..."
    
    # Try to get kagenti realm admin credentials from kagenti-test-user secret
    KAGENTI_PASSWORD=$(kubectl get secret kagenti-test-user -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$KAGENTI_PASSWORD" ]; then
        KEYCLOAK_PASSWORD="$KAGENTI_PASSWORD"
        echo "✓ Fetched Keycloak password from cluster"
    else
        echo "⚠ Could not fetch password from cluster, will try default password 'admin'"
        exit 1
    fi
    echo ""
fi

# Step 4: Enable Direct Access Grants for kagenti client if needed
echo "Step 4: Enabling Direct Access Grants for kagenti client..."

# Resolve master-realm admin credentials: prefer env vars, fall back to the
# keycloak-initial-admin secret (RHBK operator), then defaults.
KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
if [ -z "$KEYCLOAK_ADMIN_USERNAME" ] || [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    KC_ADMIN_USERNAME=$(kubectl get secret keycloak-initial-admin -n keycloak \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    KC_ADMIN_PASSWORD=$(kubectl get secret keycloak-initial-admin -n keycloak \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-${KC_ADMIN_USERNAME:-admin}}"
    KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-${KC_ADMIN_PASSWORD:-admin}}"
fi

ADMIN_TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" 2>/dev/null) || true

ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')
if [ -z "$ADMIN_TOKEN" ]; then
    echo "Error: Could not obtain master-realm admin token from Keycloak"
    echo "  Response: $ADMIN_TOKEN_RESPONSE"
    echo "  Set KEYCLOAK_ADMIN_PASSWORD in your .env if the master realm admin password is not 'admin'."
    exit 1
fi

CLIENT_CONFIG=$(curl -s "$KEYCLOAK_API/admin/realms/kagenti/clients?clientId=kagenti" \
    -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null)
CLIENT_ID=$(echo "$CLIENT_CONFIG" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"\([^"]*\)"/\1/')
if [ -z "$CLIENT_ID" ]; then
    echo "Error: Could not find kagenti client ID in Keycloak"
    echo "  Response: $CLIENT_CONFIG"
    exit 1
fi

PUT_CODE=$(curl -s -o /tmp/kc_put_response.txt -w "%{http_code}" \
    -X PUT "$KEYCLOAK_API/admin/realms/kagenti/clients/$CLIENT_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"directAccessGrantsEnabled": true}' 2>/dev/null) || PUT_CODE="000"
if [ "$PUT_CODE" != "204" ] && [ "$PUT_CODE" != "200" ]; then
    echo "Error: Failed to enable direct access grants for kagenti client (HTTP $PUT_CODE)"
    echo "  Response: $(cat /tmp/kc_put_response.txt 2>/dev/null)"
    exit 1
fi
echo "✓ Direct access grants enabled for kagenti client"

echo ""

# Step 5: Get Keycloak authentication token...
echo "Step 5: Getting Keycloak authentication token..."

# Get token from Keycloak using kagenti client (with direct access grants enabled)
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/kagenti/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=kagenti" || echo "TOKEN_ERROR")

if [ "$TOKEN_RESPONSE" = "TOKEN_ERROR" ]; then
    echo "Error: Failed to get authentication token from Keycloak"
    echo "Please check your Keycloak credentials"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to extract access token from Keycloak response"
    echo "Response: $TOKEN_RESPONSE"
    echo ""
    echo "If you see 'unauthorized_client' error, the kagenti client may need Direct Access Grants enabled."
    echo "You can enable it manually in Keycloak admin console or run this script again."
    exit 1
fi

echo "✓ Successfully obtained authentication token"

echo ""

# Step 6: Verify Kagenti backend is accessible
echo "Step 6: Verifying Kagenti backend accessibility at $KAGENTI_API..."
KAGENTI_REACHABLE=false
for i in $(seq 1 10); do
    if curl -s --max-time 5 "$KAGENTI_API/api/v1/namespaces" >/dev/null 2>&1; then
        echo "✓ Kagenti backend is accessible"
        KAGENTI_REACHABLE=true
        break
    fi
    sleep 1
done

if [ "$KAGENTI_REACHABLE" = false ]; then
    echo "Error: Kagenti backend is not accessible at $KAGENTI_API after 10s"
    echo "Please ensure Kagenti backend is reachable via HTTP route"
    exit 1
fi

echo ""

# Step 7: Delete existing tool via Kagenti API if it exists
echo "Step 7: Deleting existing tool via Kagenti API if it exists..."
DELETE_RESPONSE=$(curl -s --max-time 10 -w "%{http_code}" -o /tmp/kagenti_delete_response.txt -X DELETE "$KAGENTI_API/api/v1/tools/$NAMESPACE/$TOOL_NAME" \
    -H "Authorization: Bearer $ACCESS_TOKEN") || true

if [ -z "$DELETE_RESPONSE" ] || [ "$DELETE_RESPONSE" = "000" ]; then
    echo "Error: Could not connect to Kagenti API at $KAGENTI_API"
    echo "Please ensure Kagenti backend is accessible via HTTP route"
    exit 1
elif [ "$DELETE_RESPONSE" = "200" ] || [ "$DELETE_RESPONSE" = "404" ]; then
    echo "✓ Tool deleted or did not exist (HTTP $DELETE_RESPONSE)"

    # If the tool existed (200), wait for Kagenti to finish async cleanup before
    # re-creating. A 409 on the subsequent POST means the backend still has the
    # record; polling here prevents that race.
    if [ "$DELETE_RESPONSE" = "200" ]; then
        echo "Step 7a: Waiting for Kagenti to finish removing the old tool record..."
        GONE_WAIT=0
        GONE_MAX=30
        while true; do
            CHECK_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
                "$KAGENTI_API/api/v1/tools/$NAMESPACE/$TOOL_NAME" \
                -H "Authorization: Bearer $ACCESS_TOKEN") || CHECK_CODE="000"
            if [ "$CHECK_CODE" = "404" ]; then
                echo "✓ Tool record confirmed gone (HTTP 404)"
                break
            fi
            if [ $GONE_WAIT -ge $GONE_MAX ]; then
                echo "Error: Tool record still present after ${GONE_MAX}s — Kagenti cleanup stalled" >&2
                exit 1
            fi
            sleep 2
            GONE_WAIT=$((GONE_WAIT + 2))
        done
    fi
else
    # Any other status (e.g. 503 upstream/connection errors, 401/403) means the
    # Kagenti API is broken or unreachable. Fail fast here rather than warn and
    # continue into later steps that all hit the same dead backend.
    echo "Error: Delete returned HTTP $DELETE_RESPONSE" >&2
    echo "  Endpoint: $KAGENTI_API/api/v1/tools/$NAMESPACE/$TOOL_NAME" >&2
    echo "  Response: $(cat /tmp/kagenti_delete_response.txt)" >&2
    echo "  The Kagenti API is not healthy; aborting deployment." >&2
    exit 1
fi

# Delete MCP Gateway resources if gateway mode is enabled
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo "Deleting existing MCP Gateway resources if they exist..."
    kubectl delete httproute "${TOOL_NAME}-route" -n "$NAMESPACE" --ignore-not-found
    
    # List all mcpserverregistrations before deletion
    echo "Listing all MCPServerRegistrations in namespace $NAMESPACE..."
    EXISTING_REGS=$(kubectl get mcpserverregistrations -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_REGS" ]; then
        echo "Found MCPServerRegistrations to delete:"
        for reg in $EXISTING_REGS; do
            echo "  - $reg"
        done
        
        # Delete all mcpserverregistrations in the namespace
        kubectl delete mcpserverregistrations --all -n "$NAMESPACE" --ignore-not-found
        echo "✓ All MCPServerRegistrations deleted"
    else
        echo "✓ No MCPServerRegistrations found to delete"
    fi
    
    echo "✓ MCP Gateway resources cleaned up"
fi

echo ""

# Step 7.1: Update secrets before deployment
echo "Step 7.1: Updating secrets before deployment..."
echo ""

# Step 7.1.1 + 7.1.2: Update secrets
echo "Step 7.1.1: Updating secrets..."
if [ "$CLUSTER_MODE" = "kind" ]; then
    "$SCRIPT_DIR_BENCH/update-secrets.sh" --namespace "$NAMESPACE"
else
    echo "Step 7.1.1: Updating secrets... (skipped — secrets are pre-provisioned on OpenShift/in-cluster)"
fi

echo ""

# Step 8: Fetch and parse benchmark environment variables
echo "Step 8: Fetching and preparing benchmark environment variables..."
ENV_CONTENT=$(curl -s "https://raw.githubusercontent.com/yoavkatz/agent-examples/refs/heads/feature/exgentic-mcp-server/mcp/exgentic_benchmarks/.env.${BENCHMARK_NAME}")

# Benchmark env vars are required: a missing .env file or an unparseable
# parse-env response must abort the deploy, not silently continue with none.
if [ -z "$ENV_CONTENT" ] || echo "$ENV_CONTENT" | grep -q "404: Not Found"; then
    echo "Error: Could not fetch .env.${BENCHMARK_NAME} file" >&2
    echo "  URL: https://raw.githubusercontent.com/yoavkatz/agent-examples/refs/heads/feature/exgentic-mcp-server/mcp/exgentic_benchmarks/.env.${BENCHMARK_NAME}" >&2
    echo "  The benchmark environment file is required for deployment." >&2
    exit 1
fi

# Parse env vars using the Kagenti API
ENV_PARSE_RESPONSE=$(curl -s -X POST "$KAGENTI_API/api/v1/agents/parse-env" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"content\": $(echo "$ENV_CONTENT" | jq -Rs .)}")

# The parse-env API can return a non-JSON body (e.g. an HTML/plain-text error
# during backend 503s). Suppress jq's cryptic "Invalid numeric literal" so we
# can detect the failure and report it clearly instead of letting set -e kill
# the script on the jq line.
ENV_VARS=$(echo "$ENV_PARSE_RESPONSE" | jq '.envVars' 2>/dev/null) || ENV_VARS="null"

if [ "$ENV_VARS" = "null" ] || [ -z "$ENV_VARS" ]; then
    echo "Error: Could not parse environment variables from parse-env API" >&2
    echo "  Endpoint: $KAGENTI_API/api/v1/agents/parse-env" >&2
    echo "  Response: $ENV_PARSE_RESPONSE" >&2
    exit 1
fi
echo "✓ Environment variables parsed from .env file"

# Add runtime configuration environment variables
if [ -n "$OPENAI_API_BASE" ]; then
    echo "Adding OPENAI_API_BASE to environment variables"
    ENV_VARS=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"OPENAI_API_BASE\", \"value\": \"$OPENAI_API_BASE\"}]")
fi

# Only set EXGENTIC_SET_BENCHMARK_USER_SIMULATOR_MODEL for tau benchmarks
if [[ "$BENCHMARK_NAME" == tau* ]] && [ -n "$MODEL_NAME" ]; then
    echo "Adding EXGENTIC_SET_BENCHMARK_USER_SIMULATOR_MODEL for tau benchmark"
    ENV_VARS=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"EXGENTIC_SET_BENCHMARK_USER_SIMULATOR_MODEL\", \"value\": \"$MODEL_NAME\"}]")
fi

# Set EXGENTIC_SET_BENCHMARK_RUNNER based on benchmark type
if [[ "$BENCHMARK_NAME" == "gsm8k" ]]; then
    echo "Adding EXGENTIC_SET_BENCHMARK_RUNNER=direct for gsm8k benchmark"
    ENV_VARS=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"EXGENTIC_SET_BENCHMARK_RUNNER\", \"value\": \"direct\"}]")
fi

if [ -n "$ACTION_TIMEOUT" ]; then
    echo "Adding EXGENTIC_SET_BENCHMARK_ACTION_TIMEOUT=$ACTION_TIMEOUT"
    ENV_VARS=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"EXGENTIC_SET_BENCHMARK_ACTION_TIMEOUT\", \"value\": \"$ACTION_TIMEOUT\"}]")
fi

echo "✓ Environment variables prepared for deployment"
echo ""

# Step 9: Deploy tool using Kagenti API
echo "Step 9: Deploying tool via Kagenti API..."

# Create tool deployment JSON following Kagenti API format
TOOL_JSON=$(cat <<EOF
{
  "name": "$TOOL_NAME",
  "namespace": "$NAMESPACE",
  "protocol": "mcp",
  "framework": "custom",
  "deploymentMethod": "image",
  "containerImage": "$IMAGE_NAME",
  "workloadType": "deployment",
  "envVars": $ENV_VARS,
  "servicePorts": [
    {
      "name": "http",
      "port": 8000,
      "targetPort": 8000,
      "protocol": "TCP"
    }
  ],
  "createHttpRoute": true,
  "authBridgeEnabled": false,
  "spireEnabled": false
}
EOF
)

echo "Tool configuration:"
echo "$TOOL_JSON"
echo ""

# Deploy tool using official Kagenti API with authentication
HTTP_CODE=$(curl -s --max-time 30 -w "%{http_code}" -o /tmp/kagenti_response.txt -X POST "$KAGENTI_API/api/v1/tools" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$TOOL_JSON") || true

RESPONSE=$(cat /tmp/kagenti_response.txt)

echo "API Response (HTTP $HTTP_CODE):"
echo "$RESPONSE"
echo ""

# Check if deployment was successful
if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "Error: Could not connect to Kagenti API at $KAGENTI_API"
    echo "Please ensure Kagenti backend is accessible via HTTP route"
    exit 1
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "✓ Tool deployment successful"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "Error: Kagenti API returned 409 — tool still exists after deletion" >&2
    echo "  This means the delete completed but Kagenti's cleanup is not done." >&2
    echo "  Response: $RESPONSE" >&2
    exit 1
else
    echo "Error: Kagenti API deployment failed with HTTP $HTTP_CODE"
    echo "Response: $RESPONSE"
    echo ""
    echo "Please ensure:"
    echo "  1. Kagenti API is running at $KAGENTI_API"
    echo "  2. The API endpoint is correct"
    echo "  3. You have proper permissions"
    exit 1
fi
echo ""

# Step 10: Patch imagePullPolicy to IfNotPresent (local images only)
if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    echo "Step 10: Patching imagePullPolicy to IfNotPresent..."
    sleep 2  # Give the deployment a moment to be created
    kubectl patch deployment $TOOL_NAME -n $NAMESPACE -p '{"spec":{"template":{"spec":{"containers":[{"name":"mcp","imagePullPolicy":"IfNotPresent"}]}}}}' 2>/dev/null || echo "Warning: Could not patch imagePullPolicy"
    echo "✓ ImagePullPolicy patched"
else
    echo "Step 10: Patching imagePullPolicy... (skipped, K8s will pull from remote registry)"
fi

echo ""

# Step 11: Wait for MCP server to be ready.
# Uses an HTTP health check against the cluster-internal service URL — kubectl is
# not available inside the job container.
echo "Step 11: Waiting for MCP server to be ready..."

MCP_URL="$(tool_http_url "$TOOL_NAME" "$NAMESPACE")"
echo "  MCP URL: $MCP_URL"

MCP_READY=false
MCP_MAX_WAIT=300
for i in $(seq 1 $MCP_MAX_WAIT); do
    MCP_HTTP_CODE=$(curl -s -o /tmp/mcp_health_response.txt -w "%{http_code}" --max-time 3 \
        -X POST "$MCP_URL/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' \
        2>/dev/null) || MCP_HTTP_CODE="000"
    MCP_RESPONSE=$(cat /tmp/mcp_health_response.txt 2>/dev/null || echo "")

    if [ "$MCP_HTTP_CODE" = "200" ]; then
        echo "✓ MCP server is ready (HTTP 200)"
        echo "  Service: $MCP_URL"
        MCP_READY=true
        break
    fi

    if [ $((i % 15)) -eq 0 ]; then
        if echo "$MCP_RESPONSE" | grep -q "upstream connect error\|reset before headers\|no healthy upstream"; then
            echo "  Gateway error — pod not ready yet... (${i}s)"
        else
            echo "  Waiting for MCP server... HTTP $MCP_HTTP_CODE (${i}s)"
        fi
    fi
    sleep 1
done

if [ "$MCP_READY" = false ]; then
    echo "Error: MCP server did not become ready within ${MCP_MAX_WAIT}s" >&2
    echo "  Last HTTP code: $MCP_HTTP_CODE" >&2
    echo "  Last response:  $MCP_RESPONSE" >&2
    exit 1
fi

echo ""

# Step 12: Set resource limits (local/dev only — kubectl not available in-cluster).
if [ "$CLUSTER_MODE" = "in-cluster" ]; then
    echo "Step 12: Setting resource limits... (skipped — kubectl not available in-cluster)"
else
    echo "Step 12.1: Setting resource limits..."
    kubectl set resources deployment/$TOOL_NAME -n $NAMESPACE \
        --limits=cpu=4,memory=4Gi \
        --requests=cpu=500m,memory=512Mi 2>/dev/null \
        && echo "✓ Benchmark resource limits set (CPU: 4 cores, Memory: 4Gi)" \
        || echo "Warning: Could not set resource limits"
    echo ""

    echo "Step 12.2: Waiting for deployment to stabilize..."
    kubectl rollout status deployment/$TOOL_NAME -n $NAMESPACE --timeout=120s
    echo "✓ Deployment stable"
fi

# Step 14: Register with MCP Gateway (conditional)
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    echo ""
    echo "=========================================="
    echo "Step 14: Registering MCP server with Gateway"
    echo "=========================================="
    echo ""

    # Kagenti appends -mcp to the service name
    MCP_SVC_NAME="${TOOL_NAME}-mcp"
    if ! kubectl get svc "$MCP_SVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        MCP_SVC_NAME="$TOOL_NAME"
    fi

    echo "Creating HTTPRoute for $TOOL_NAME..."
    kubectl apply -f - <<ROUTE_EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${TOOL_NAME}-route
  namespace: ${NAMESPACE}
  labels:
    mcp-server: "true"
spec:
  parentRefs:
  - name: mcp-gateway
    namespace: gateway-system
  hostnames:
  - "${TOOL_NAME}.mcp.local"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: ${MCP_SVC_NAME}
      port: 8000
ROUTE_EOF

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create HTTPRoute"
        exit 1
    fi
    echo "✓ HTTPRoute created"
    echo ""

    echo "Creating MCPServerRegistration for $TOOL_NAME..."
    kubectl apply -f - <<REG_EOF
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPServerRegistration
metadata:
  name: ${TOOL_NAME}-servers
  namespace: ${NAMESPACE}
spec:
  toolPrefix: exgentic_${BENCHMARK_NAME}_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ${TOOL_NAME}-route
    namespace: ${NAMESPACE}
REG_EOF

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create MCPServerRegistration"
        exit 1
    fi
    echo "✓ MCPServerRegistration created"
    echo ""

    echo "Waiting for MCPServerRegistration to become Ready..."
    GATEWAY_MAX_WAIT=120
    GATEWAY_ELAPSED=0
    while [ $GATEWAY_ELAPSED -lt $GATEWAY_MAX_WAIT ]; do
        REG_STATUS=$(kubectl get mcpserverregistrations "${TOOL_NAME}-servers" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [ "$REG_STATUS" = "True" ]; then
            echo "✓ MCPServerRegistration is Ready"
            break
        fi

        if [ $((GATEWAY_ELAPSED % 15)) -eq 0 ] && [ $GATEWAY_ELAPSED -gt 0 ]; then
            echo "  Waiting for MCPServerRegistration... (${GATEWAY_ELAPSED}s)"
        fi
        sleep 5
        GATEWAY_ELAPSED=$((GATEWAY_ELAPSED + 5))
    done

    if [ $GATEWAY_ELAPSED -ge $GATEWAY_MAX_WAIT ]; then
        echo "⚠ MCPServerRegistration did not become Ready within ${GATEWAY_MAX_WAIT}s"
        echo "  Check status: kubectl get mcpserverregistrations ${TOOL_NAME}-servers -n $NAMESPACE -o yaml"
        echo "  Continuing anyway..."
    fi

    echo ""
fi

echo ""
echo "=========================================="
echo "Deployment and Configuration Complete!"
echo "=========================================="
echo ""
echo "Benchmark configuration:"
echo "  Deployment: $TOOL_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Model: $MODEL_NAME"
if [ -n "$ACTION_TIMEOUT" ]; then
    echo "  Action Timeout: ${ACTION_TIMEOUT}s"
fi
if [ -n "$OPENAI_API_BASE" ]; then
    echo "  Memory Limit: 3Gi"
    echo "  OPENAI_API_BASE: $OPENAI_API_BASE"
    if [[ "$BENCHMARK_NAME" == tau* ]]; then
        echo "  EXGENTIC_SET_BENCHMARK_USER_SIMULATOR_MODEL: $MODEL_NAME"
    fi
    if [ -n "$OPENAI_API_KEY" ]; then
        echo "  OPENAI_API_KEY: (updated from env var)"
    fi
    if [ -n "$HF_TOKEN" ]; then
        echo "  HF_TOKEN: (updated from env var)"
    fi
fi
echo ""
echo "To access the tool:"
echo "  URL: $(tool_http_url "$TOOL_NAME" "$NAMESPACE")"
echo ""

# Made with Bob
