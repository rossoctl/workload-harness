#!/bin/bash
# Deploy and Configure Exgentic benchmark to Kagenti cluster
# Usage: ./deploy-benchmark.sh --benchmark <name> [OPTIONS]
# Example: ./deploy-benchmark.sh --benchmark gsm8k
# Example: ./deploy-benchmark.sh --benchmark tau2 --model Azure/gpt-4o-mini
# Example: ./deploy-benchmark.sh --benchmark tau2 --model Azure/gpt-4o-mini --keycloak-user admin --keycloak-pass admin

set -e

# Default values
MODEL_NAME="Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="unknown"
BENCHMARK_NAME=""
USE_MCP_GATEWAY="false"
USE_LOCAL_IMAGE="false"

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
        -h|--help)
            echo "Usage: $0 --benchmark <name> [OPTIONS]"
            echo ""
            echo "Required Arguments:"
            echo "  --benchmark NAME           Benchmark name (e.g., gsm8k, tau2)"
            echo ""
            echo "Optional Arguments:"
            echo "  --model MODEL              Model name (default: Azure/gpt-4.1)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (auto-detected from cluster if not provided)"
            echo "  --use-mcp-gateway          Register MCP server with the MCP Gateway"
            echo "  --local-image              Use locally built image instead of pulling from registry"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark gsm8k"
            echo "  $0 --benchmark tau2 --model Azure/gpt-4o-mini"
            echo "  $0 --benchmark tau2 --model Azure/gpt-4o-mini --keycloak-user admin --keycloak-pass admin"
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

# Default to Exgentic registry, can be overridden with environment variable
EXGENTIC_REGISTRY="${EXGENTIC_REGISTRY:-ghcr.io/exgentic}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REMOTE_IMAGE_NAME="${EXGENTIC_REGISTRY}/exgentic-mcp-${BENCHMARK_NAME}:${IMAGE_TAG}"
LOCAL_IMAGE_NAME="localhost/exgentic-mcp-${BENCHMARK_NAME}:latest"
TOOL_NAME="exgentic-mcp-${BENCHMARK_NAME}"
NAMESPACE="team1"
KAGENTI_API="http://kagenti-api.localtest.me:8080"
KEYCLOAK_API="http://keycloak.localtest.me:8080"

echo "=========================================="
echo "Deploying Exgentic Benchmark: $BENCHMARK_NAME"
echo "=========================================="
echo "Model: $MODEL_NAME"
echo ""

# Step 1: Determine container runtime and get image
echo "Step 1: Setting up container image..."
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Error: Neither podman nor docker found"
    exit 1
fi

echo "Using container runtime: $CONTAINER_CMD"

if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    # Force use of local image
    echo "Using local image (--local-image flag set): $LOCAL_IMAGE_NAME"
    IMAGE_NAME="$LOCAL_IMAGE_NAME"
    
    if ! $CONTAINER_CMD image inspect "$IMAGE_NAME" &> /dev/null; then
        echo "Error: Local image $IMAGE_NAME not found"
        echo "Please build the image first"
        exit 1
    fi
    
    echo "✓ Local image found: $IMAGE_NAME"
else
    # Try to use remote image from Exgentic registry first
    IMAGE_NAME="$REMOTE_IMAGE_NAME"
    echo "Attempting to pull image from Exgentic registry: $REMOTE_IMAGE_NAME"
    
    if $CONTAINER_CMD pull "$REMOTE_IMAGE_NAME" ; then
        echo "✓ Successfully pulled image from Exgentic registry"
        # Tag it as localhost for kind compatibility
        $CONTAINER_CMD tag "$REMOTE_IMAGE_NAME" "$LOCAL_IMAGE_NAME"
        IMAGE_NAME="$LOCAL_IMAGE_NAME"
    else
        echo "Warning: Could not pull from Exgentic registry, checking for local image..."
        IMAGE_NAME="$LOCAL_IMAGE_NAME"
        
        if ! $CONTAINER_CMD image inspect "$IMAGE_NAME" &> /dev/null; then
            echo "Error: Image $IMAGE_NAME not found locally and could not pull from registry"
            echo "Please either:"
            echo "  1. Build the image locally and use --local-image flag, or"
            echo "  2. Ensure you have access to $REMOTE_IMAGE_NAME"
            exit 1
        fi
        
        echo "✓ Using local image: $IMAGE_NAME"
    fi
fi

echo ""

# Step 2: Check if image needs syncing
echo "Step 2: Checking if image sync is needed..."
if ! command -v kind &> /dev/null; then
    echo "Error: kind command not found"
    exit 1
fi

# Get local image ID
LOCAL_IMAGE_ID=$($CONTAINER_CMD inspect "$IMAGE_NAME" --format='{{.Id}}' 2>/dev/null || echo "")

if [ -z "$LOCAL_IMAGE_ID" ]; then
    echo "Error: Could not get local image ID"
    exit 1
fi

echo "Local image ID: $LOCAL_IMAGE_ID"

# Get cluster image ID (check if image exists in cluster)
# Use podman if available, otherwise docker
if command -v podman &> /dev/null; then
    CLUSTER_IMAGE_ID=$(podman exec kagenti-control-plane crictl inspecti "$IMAGE_NAME" 2>/dev/null | grep '"id":' | head -1 | sed 's/.*"id": *"\([^"]*\)".*/\1/' || echo "")
else
    CLUSTER_IMAGE_ID=$(docker exec kagenti-control-plane crictl inspecti "$IMAGE_NAME" 2>/dev/null | grep '"id":' | head -1 | sed 's/.*"id": *"\([^"]*\)".*/\1/' || echo "")
fi

# Normalize IDs by removing sha256: prefix if present
LOCAL_IMAGE_ID_NORMALIZED="${LOCAL_IMAGE_ID#sha256:}"
CLUSTER_IMAGE_ID_NORMALIZED="${CLUSTER_IMAGE_ID#sha256:}"

if [ -z "$CLUSTER_IMAGE_ID" ]; then
    echo "Image not found in cluster, syncing..."
    NEED_SYNC=true
elif [ "$LOCAL_IMAGE_ID_NORMALIZED" != "$CLUSTER_IMAGE_ID_NORMALIZED" ]; then
    echo "Cluster image ID: $CLUSTER_IMAGE_ID"
    echo "Images differ, syncing..."
    NEED_SYNC=true
else
    echo "Cluster image ID: $CLUSTER_IMAGE_ID"
    echo "✓ Images match, skipping sync"
    NEED_SYNC=false
fi

if [ "$NEED_SYNC" = true ]; then
    echo "Saving and loading image..."
    $CONTAINER_CMD save "$IMAGE_NAME" | kind load image-archive /dev/stdin --name kagenti
    echo "✓ Image synced to kind-kagenti cluster"
fi

echo ""

# Step 3: Verify Keycloak is accessible
echo "Step 3: Verifying Keycloak is accessible at $KEYCLOAK_API..."
if curl -s --max-time 5 $KEYCLOAK_API/health >/dev/null 2>&1; then
    echo "✓ Keycloak is accessible"
else
    echo "Warning: Could not verify Keycloak accessibility, continuing anyway..."
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
        KEYCLOAK_PASSWORD="admin"
    fi
    echo ""
fi

# Step 4: Enable Direct Access Grants for kagenti client if needed
echo "Step 4: Enabling Direct Access Grants for kagenti client..."

# Get admin token first (use "admin" password for master realm)
ADMIN_TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=admin" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" 2>/dev/null || echo "TOKEN_ERROR")

if [ "$ADMIN_TOKEN_RESPONSE" != "TOKEN_ERROR" ]; then
    ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')
    
    if [ -n "$ADMIN_TOKEN" ]; then
        # Get kagenti client configuration
        CLIENT_CONFIG=$(curl -s "$KEYCLOAK_API/admin/realms/kagenti/clients?clientId=kagenti" \
            -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null)
        
        CLIENT_ID=$(echo "$CLIENT_CONFIG" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"\([^"]*\)"/\1/')
        
        if [ -n "$CLIENT_ID" ]; then
            # Enable direct access grants
            curl -s -X PUT "$KEYCLOAK_API/admin/realms/kagenti/clients/$CLIENT_ID" \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{"directAccessGrantsEnabled": true}' >/dev/null 2>&1
            echo "✓ Direct access grants enabled for kagenti client"
        fi
    fi
fi

echo ""

# Step 4.5: Verify Keycloak password works now that Direct Access Grants is enabled
echo "Step 4.5: Verifying Keycloak authentication..."
TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/kagenti/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=kagenti" 2>/dev/null || echo "")

if ! echo "$TEST_AUTH" | grep -q "access_token"; then
    echo "⚠ Warning: Authentication failed with current password"
    echo "Response: $TEST_AUTH"
    echo "Please provide the correct password using --keycloak-pass option"
    exit 1
fi
echo "✓ Keycloak authentication verified"

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

# Step 6: Set up port-forward to Kagenti backend
echo "Step 6: Setting up port-forward to Kagenti backend..."

# Check if Kagenti API is accessible
if curl -s --max-time 5 "$KAGENTI_API/api/v1/namespaces" >/dev/null 2>&1; then
    echo "✓ Kagenti backend is accessible"
else
    echo "Warning: Could not verify Kagenti backend accessibility, continuing anyway..."
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
else
    echo "Warning: Delete returned HTTP $DELETE_RESPONSE"
    cat /tmp/kagenti_delete_response.txt
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

# Wait a moment for deletion to complete
sleep 3

echo ""

# Step 7.1: Update secrets before deployment
echo "Step 7.1: Updating secrets before deployment..."
echo ""

# Step 7.1.1: Update the openai-secret with current OPENAI_API_KEY
echo "Step 7.1.1: Updating openai-secret with OPENAI_API_KEY..."

if [ -z "$OPENAI_API_KEY" ]; then
    echo "Warning: OPENAI_API_KEY environment variable is not set"
    echo "Skipping secret update"
else
    # Encode the API key in base64
    ENCODED_KEY=$(echo -n "$OPENAI_API_KEY" | base64)
    
    # Patch the secret
    kubectl patch secret openai-secret -n $NAMESPACE --type='json' -p="[
      {
        \"op\": \"replace\",
        \"path\": \"/data/apikey\",
        \"value\": \"$ENCODED_KEY\"
      }
    ]" 2>/dev/null && echo "✓ OPENAI_API_KEY secret updated" || echo "Warning: Could not update OPENAI_API_KEY secret"
fi

echo ""

# Step 7.1.2: Update the hf-secret with current HF_TOKEN
echo "Step 7.1.2: Updating hf-secret with HF_TOKEN..."

# Use HF_TOKEN from environment or set a dummy token if not defined
if [ -z "$HF_TOKEN" ]; then
    echo "Warning: HF_TOKEN environment variable is not set, using dummy token"
    HF_TOKEN_VALUE="dummy-hf-token-not-set"
else
    HF_TOKEN_VALUE="$HF_TOKEN"
fi

# Encode the HF token in base64
ENCODED_HF_TOKEN=$(echo -n "$HF_TOKEN_VALUE" | base64)

# Check if hf-secret exists, create or patch accordingly
if kubectl get secret hf-secret -n $NAMESPACE >/dev/null 2>&1; then
    # Patch existing secret
    kubectl patch secret hf-secret -n $NAMESPACE --type='json' -p="[
      {
        \"op\": \"replace\",
        \"path\": \"/data/hf-token\",
        \"value\": \"$ENCODED_HF_TOKEN\"
      }
    ]" 2>/dev/null && echo "✓ HF_TOKEN secret updated" || echo "Warning: Could not update HF_TOKEN secret"
else
    # Create new secret
    kubectl create secret generic hf-secret -n $NAMESPACE \
        --from-literal=hf-token="$HF_TOKEN_VALUE" 2>/dev/null && echo "✓ HF_TOKEN secret created" || echo "Warning: Could not create HF_TOKEN secret"
fi

echo ""

# Step 8: Fetch and parse benchmark environment variables
echo "Step 8: Fetching and preparing benchmark environment variables..."
ENV_CONTENT=$(curl -s "https://raw.githubusercontent.com/yoavkatz/agent-examples/refs/heads/feature/exgentic-mcp-server/mcp/exgentic_benchmarks/.env.${BENCHMARK_NAME}")

if [ -z "$ENV_CONTENT" ] || echo "$ENV_CONTENT" | grep -q "404: Not Found"; then
    echo "Warning: Could not fetch .env.${BENCHMARK_NAME} file, deploying without custom env vars"
    ENV_VARS="[]"
else
    # Parse env vars using the Kagenti API
    ENV_PARSE_RESPONSE=$(curl -s -X POST "$KAGENTI_API/api/v1/agents/parse-env" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "{\"content\": $(echo "$ENV_CONTENT" | jq -Rs .)}")
    
    ENV_VARS=$(echo "$ENV_PARSE_RESPONSE" | jq '.envVars')
    
    if [ "$ENV_VARS" = "null" ] || [ -z "$ENV_VARS" ]; then
        echo "Warning: Could not parse environment variables, deploying without custom env vars"
        ENV_VARS="[]"
    else
        echo "✓ Environment variables parsed from .env file"
    fi
fi

# Add runtime configuration environment variables
if [ -n "$OPENAI_API_BASE" ]; then
    echo "Adding OPENAI_API_BASE to environment v   ariables"
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
    echo "✓ Tool already exists (HTTP 409)"
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

# Step 10: Patch imagePullPolicy to IfNotPresent for local images
echo "Step 10: Patching imagePullPolicy to IfNotPresent..."
sleep 2  # Give the deployment a moment to be created
kubectl patch deployment $TOOL_NAME -n $NAMESPACE -p '{"spec":{"template":{"spec":{"containers":[{"name":"mcp","imagePullPolicy":"IfNotPresent"}]}}}}' 2>/dev/null || echo "Warning: Could not patch imagePullPolicy"
echo "✓ ImagePullPolicy patched"

echo ""

# Step 11: Wait for tool to be ready
echo "Step 11: Waiting for tool to be ready..."

MAX_WAIT=120
WAIT_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if pod is running (using Kagenti's label format)
    POD_STATUS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$TOOL_NAME -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD_STATUS" = "Running" ]; then
        # Check if pod is ready
        POD_READY=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$TOOL_NAME -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [ "$POD_READY" = "True" ]; then
            echo "✓ Tool is ready!"
            
            # Get pod name
            POD_NAME=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$TOOL_NAME -o jsonpath='{.items[0].metadata.name}')
            echo ""
            echo "Pod: $POD_NAME"
            echo "Service: $TOOL_NAME.$NAMESPACE:8000"
            echo ""
            break
        fi
    fi
    
    echo "  Status: $POD_STATUS (waiting...)"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "Error: Tool did not become ready within ${MAX_WAIT}s"
    echo ""
    echo "Check status with:"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=$TOOL_NAME"
    echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=$TOOL_NAME"
    exit 1
fi

echo ""

# Step 12: Update openai-secret and set memory limit

# Step 12.1: Set resource limits
echo "Step 12.1: Setting resource limits..."

# Set CPU limit to 4 cores and memory limit to 4GB
kubectl set resources deployment/$TOOL_NAME -n $NAMESPACE \
    --limits=cpu=4,memory=4Gi \
    --requests=cpu=500m,memory=512Mi 2>/dev/null && echo "✓ Benchmark resource limits set (CPU: 4 cores, Memory: 4Gi)" || echo "Warning: Could not set resource limits"

echo ""

# Step 12.2: Wait for any configuration changes to roll out
echo "Step 12.2: Waiting for deployment to stabilize..."
kubectl rollout status deployment/$TOOL_NAME -n $NAMESPACE --timeout=120s
echo "✓ Deployment stable"
echo ""

echo ""

# Step 13: Health check MCP server
echo "Step 13: Performing MCP server health check..."
echo ""

# Use HTTP route endpoint instead of port-forward
MCP_HTTP_ROUTE_URL="http://${TOOL_NAME}.${NAMESPACE}.localtest.me:8080"
MCP_API="$MCP_HTTP_ROUTE_URL"

echo "Using HTTP route URL: $MCP_HTTP_ROUTE_URL"

# Wait for HTTP route to be ready (up to 60s)
HEALTH_CHECK_PASSED=false
for i in $(seq 1 60); do
    # Health check: POST an MCP initialize request to /mcp
    MCP_HTTP_CODE=$(curl -s -o /tmp/mcp_health_response.txt -w "%{http_code}" --max-time 3 \
        -X POST "$MCP_API/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' \
        2>/dev/null) || true
    
    MCP_RESPONSE=$(cat /tmp/mcp_health_response.txt 2>/dev/null || echo "")

    if [ "$MCP_HTTP_CODE" = "200" ]; then
        echo "✓ MCP server health check passed (HTTP 200 on /mcp)"
        HEALTH_CHECK_PASSED=true
        break
    fi
    
    # Check for gateway errors
    if echo "$MCP_RESPONSE" | grep -q "upstream connect error\|reset before headers\|no healthy upstream"; then
        if [ $((i % 10)) -eq 0 ]; then
            echo "  Gateway error (backend not ready yet)... (${i}s)"
        fi
    elif [ $((i % 10)) -eq 0 ]; then
        echo "  Waiting for MCP server to be ready... (${i}s)"
    fi
    sleep 1
done

if [ "$HEALTH_CHECK_PASSED" = false ]; then
    echo "⚠ MCP server did not respond to health check after 60s"
    if [ -n "$MCP_RESPONSE" ]; then
        echo "  Last response: $MCP_RESPONSE"
    fi
    echo "  The server may still be starting up or HTTP route may not be fully configured"
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
echo "  HTTP Route URL: http://${TOOL_NAME}.${NAMESPACE}.localtest.me:8080"
echo ""

# Made with Bob
