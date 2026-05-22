#!/bin/bash
# Deploy and Configure agent to Kagenti cluster via API
# Usage: ./deploy-agent.sh --benchmark <name> --agent <name> [OPTIONS]
# Example: ./deploy-agent.sh --benchmark gsm8k --agent generic_agent
# Example: ./deploy-agent.sh --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini

set -e

# Default values
MODEL_NAME="Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="unknown"
BENCHMARK_NAME=""
AGENT_NAME_INPUT=""
USE_MCP_GATEWAY="false"
# IBAC_ENABLED lets .env pre-set the default; --ibac / --no-ibac always override.
USE_IBAC="${IBAC_ENABLED:-false}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --benchmark)
            BENCHMARK_NAME="$2"
            shift 2
            ;;
        --agent)
            AGENT_NAME_INPUT="$2"
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
        --ibac)
            USE_IBAC="true"
            shift
            ;;
        --no-ibac)
            USE_IBAC="false"
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
            echo "  --model MODEL              Model name (default: Azure/gpt-4.1)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (auto-detected from cluster if not provided)"
            echo "  --use-mcp-gateway          Connect agent to MCP Gateway instead of direct MCP server"
            echo "  --ibac                     Enable IBAC by patching the authbridge sidecar's plugin pipeline"
            echo "  --no-ibac                  Deploy without IBAC (default; overrides IBAC_ENABLED env)"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "IBAC Environment Variables (used with --ibac):"
            echo "  IBAC_ENABLED                 Default for --ibac flag if set to true"
            echo "  IBAC_JUDGE_ENDPOINT          Judge LLM base URL (default: http://host.docker.internal:11434)"
            echo "  IBAC_JUDGE_MODEL             Judge model id (default: llama3.2:3b)"
            echo "  IBAC_AGENT_LLM_HOST          Hostname of the agent's own LLM (auto-derived from OPENAI_API_BASE)"
            echo "  IBAC_TIMEOUT_MS              Per-judge-call timeout in ms (default: 15000)"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark gsm8k --agent generic_agent"
            echo "  $0 --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini"
            echo "  $0 --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini --keycloak-user admin --keycloak-pass admin"
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

if [ -z "$BENCHMARK_NAME" ] || [ -z "$AGENT_NAME_INPUT" ]; then
    echo "Error: Both --benchmark and --agent are required"
    echo "Usage: $0 --benchmark <name> --agent <name> [OPTIONS]"
    echo "Use --help for more information"
    exit 1
fi

# Determine deployment type based on agent name
if [ "$AGENT_NAME_INPUT" = "generic_agent" ]; then
    DEPLOYMENT_TYPE="source"
    AGENT_NAME="generic-agent-internal-${BENCHMARK_NAME}"
else
    DEPLOYMENT_TYPE="image"
    # Automatically add exgentic-a2a- prefix if not already present
    if [[ "$AGENT_NAME_INPUT" == exgentic-a2a-* ]]; then
        FULL_AGENT_NAME="$AGENT_NAME_INPUT"
    else
        FULL_AGENT_NAME="exgentic-a2a-${AGENT_NAME_INPUT}"
    fi
    # Replace underscores with hyphens for Kubernetes compatibility
    AGENT_NAME="${FULL_AGENT_NAME}-${BENCHMARK_NAME}"
    AGENT_NAME="${AGENT_NAME//_/-}"
    # Image name keeps underscores (container images allow them)
    IMAGE_NAME="localhost/${FULL_AGENT_NAME}:latest"
    # Split image name and tag for API
    IMAGE_NAME_WITHOUT_TAG="localhost/${FULL_AGENT_NAME}"
    IMAGE_TAG="latest"
fi

TOOL_NAME="exgentic-mcp-${BENCHMARK_NAME}"
NAMESPACE="team1"
KAGENTI_API="http://localhost:8001"
KAGENTI_PORT=8001
KEYCLOAK_API="http://localhost:8002"
KEYCLOAK_PORT=8002

echo "=========================================="
if [ "$DEPLOYMENT_TYPE" = "source" ]; then
    echo "Deploying Generic Agent: $AGENT_NAME"
else
    echo "Deploying Exgentic Agent: $AGENT_NAME"
    echo "From image: $IMAGE_NAME"
fi
echo "Model: $MODEL_NAME"
echo "=========================================="
echo ""

# Step 0: If deploying from image, check and sync image
if [ "$DEPLOYMENT_TYPE" = "image" ]; then
    echo "Step 0: Checking for local image and syncing if needed..."
    
    # Determine container runtime
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
    else
        echo "Error: Neither podman nor docker found"
        exit 1
    fi
    
    echo "Using container runtime: $CONTAINER_CMD"
    
    # Check if image exists locally
    if ! $CONTAINER_CMD image inspect "$IMAGE_NAME" &> /dev/null; then
        echo "Error: Image $IMAGE_NAME not found locally"
        echo "Please build the image first"
        exit 1
    fi
    
    echo "✓ Image $IMAGE_NAME found locally"
    
    # Check if kind is available
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
fi

# Step 1: Set up port-forward to Keycloak
echo "Step 1: Setting up port-forward to Keycloak..."
if lsof -Pi :$KEYCLOAK_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "✓ Port $KEYCLOAK_PORT is already in use (assuming Keycloak is accessible)"
else
    echo "Starting port-forward to keycloak on port $KEYCLOAK_PORT..."
    kubectl port-forward -n keycloak svc/keycloak-service $KEYCLOAK_PORT:8080 >/dev/null 2>&1 &
    KEYCLOAK_PF_PID=$!
    sleep 2
fi

echo ""

# Step 1.5: Auto-fetch Keycloak password from cluster if using default
if [ "$KEYCLOAK_PASSWORD" = "unknown" ]; then
    echo "Step 1.5: Attempting to fetch Keycloak password from cluster..."
    
    # Try to get kagenti realm admin credentials from kagenti-test-user secret
    KAGENTI_PASSWORD=$(kubectl get secret kagenti-test-user -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$KAGENTI_PASSWORD" ]; then
        # Test if the fetched password works
        TEST_AUTH=$(curl -s -X POST "http://localhost:$KEYCLOAK_PORT/realms/kagenti/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=admin" \
            -d "password=$KAGENTI_PASSWORD" \
            -d "grant_type=password" \
            -d "client_id=kagenti" 2>/dev/null || echo "")
        
        if echo "$TEST_AUTH" | grep -q "access_token"; then
            KEYCLOAK_PASSWORD="$KAGENTI_PASSWORD"
            echo "✓ Successfully fetched and verified Keycloak password from cluster"
        else
            echo "⚠ Warning: Fetched password from cluster but authentication failed"
            echo "Please provide the correct password using --keycloak-pass option"
            exit 1
        fi
    else
        # Fallback: test if default password works
        TEST_AUTH=$(curl -s -X POST "http://localhost:$KEYCLOAK_PORT/realms/kagenti/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=admin" \
            -d "password=admin" \
            -d "grant_type=password" \
            -d "client_id=kagenti" 2>/dev/null || echo "")
        
        if echo "$TEST_AUTH" | grep -q "access_token"; then
            KEYCLOAK_PASSWORD="admin"
            echo "✓ Using default Keycloak password"
        else
            echo "⚠ Warning: Could not fetch password from cluster and default password doesn't work"
            echo "Please provide the correct password using --keycloak-pass option"
            exit 1
        fi
    fi
    echo ""
fi

# Step 2: Enable Direct Access Grants for kagenti client if needed
echo "Step 2: Enabling Direct Access Grants for kagenti client..."

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

# Step 2.5: Verify Keycloak password works now that Direct Access Grants is enabled
echo "Step 2.5: Verifying Keycloak authentication..."
TEST_AUTH=$(curl -s -X POST "http://localhost:$KEYCLOAK_PORT/realms/kagenti/protocol/openid-connect/token" \
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

# Step 3: Get Keycloak authentication token
echo "Step 3: Getting Keycloak authentication token..."
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/kagenti/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=kagenti" || echo "TOKEN_ERROR")

if [ "$TOKEN_RESPONSE" = "TOKEN_ERROR" ]; then
    echo "Error: Failed to get authentication token from Keycloak"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    echo ""
    echo "If you see 'unauthorized_client' error, the kagenti client may need Direct Access Grants enabled."
    echo "You can enable it manually in Keycloak admin console or run this script again."
    exit 1
fi

echo "✓ Successfully obtained authentication token"

echo ""

# Step 4: Set up port-forward to Kagenti backend
echo "Step 4: Setting up port-forward to Kagenti backend..."
if curl -s --max-time 3 "$KAGENTI_API/api/v1/namespaces" >/dev/null 2>&1; then
    echo "✓ Kagenti backend is already accessible on port $KAGENTI_PORT"
else
    # Kill any stale port-forward that has the port open but isn't working
    if lsof -Pi :$KAGENTI_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "Port $KAGENTI_PORT is open but API not responding, restarting port-forward..."
        lsof -ti :$KAGENTI_PORT | xargs kill 2>/dev/null || true
        sleep 1
    fi

    echo "Starting port-forward to kagenti-backend on port $KAGENTI_PORT..."
    kubectl port-forward -n kagenti-system svc/kagenti-backend $KAGENTI_PORT:8000 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!

    echo "Waiting for port-forward to be ready..."
    for i in {1..10}; do
        if curl -s --max-time 3 "$KAGENTI_API/api/v1/namespaces" >/dev/null 2>&1; then
            echo "✓ Port-forward is ready"
            break
        fi
        if [ $i -eq 10 ]; then
            echo "Error: Port-forward failed to become ready"
            kill $PORT_FORWARD_PID 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
fi

echo ""

# Step 5: Delete existing agent if it exists
echo "Step 5: Deleting existing agent via Kagenti API if it exists..."
DELETE_RESPONSE=$(curl -s --max-time 10 -w "%{http_code}" -o /tmp/kagenti_delete_agent_response.txt -X DELETE "$KAGENTI_API/api/v1/agents/$NAMESPACE/$AGENT_NAME" \
    -H "Authorization: Bearer $ACCESS_TOKEN") || true

if [ -z "$DELETE_RESPONSE" ] || [ "$DELETE_RESPONSE" = "000" ]; then
    echo "Error: Could not connect to Kagenti API at $KAGENTI_API"
    echo "Please ensure the port-forward to kagenti-backend is running:"
    echo "  kubectl port-forward -n kagenti-system svc/kagenti-backend $KAGENTI_PORT:8000"
    exit 1
elif [ "$DELETE_RESPONSE" = "200" ] || [ "$DELETE_RESPONSE" = "404" ]; then
    echo "✓ Agent deleted or did not exist (HTTP $DELETE_RESPONSE)"
else
    echo "Warning: Delete returned HTTP $DELETE_RESPONSE"
fi

sleep 3

echo ""

# Step 6: Fetch and parse environment variables
echo "Step 6: Fetching environment variables..."

if [ "$DEPLOYMENT_TYPE" = "source" ]; then
    # Generic agent - fetch from agent-examples repo
    ENV_FILE_URL="https://raw.githubusercontent.com/kagenti/agent-examples/refs/heads/main/a2a/generic_agent/.env.openai"
else
    # Exgentic agent - fetch env file for specific agent
    ENV_FILE_URL="https://raw.githubusercontent.com/yoavkatz/agent-examples/refs/heads/feature/exgentic-mcp-server/a2a/exgentic_agent/.env.example"
fi

ENV_CONTENT=$(curl -s "$ENV_FILE_URL")

if [ -z "$ENV_CONTENT" ] || echo "$ENV_CONTENT" | grep -q "404: Not Found"; then
    echo "Error: Could not fetch env file"
    echo "Expected file: $ENV_FILE_URL"
    exit 1
fi

# Parse env vars using the Kagenti API
ENV_PARSE_RESPONSE=$(curl -s --max-time 10 -X POST "$KAGENTI_API/api/v1/agents/parse-env" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "{\"content\": $(echo "$ENV_CONTENT" | jq -Rs .)}") || true

ENV_VARS=$(echo "$ENV_PARSE_RESPONSE" | jq '.envVars')

if [ "$ENV_VARS" = "null" ] || [ -z "$ENV_VARS" ]; then
    echo "Error: Could not parse environment variables"
    echo "Response: $ENV_PARSE_RESPONSE"
    exit 1
fi

echo "✓ Environment variables parsed from .env file"

echo ""

# Step 7: Prepare environment variables for deployment
echo "Step 7: Preparing environment variables for deployment..."

# Add MCP_URL(S) to environment variables
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    MCP_URL="http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080/mcp"
    echo "Using MCP Gateway URL: $MCP_URL"
else
    MCP_URL="http://${TOOL_NAME}-mcp:8000/mcp"
fi

if [ "$DEPLOYMENT_TYPE" = "source" ]; then
    # Generic agent uses MCP_URLS
    ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"MCP_URLS\", \"value\": \"$MCP_URL\"}]")
else
    # Exgentic agent uses MCP_URL
    ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"MCP_URL\", \"value\": \"$MCP_URL\"}]")
fi

# Add runtime configuration environment variables
if [ -n "$OPENAI_API_BASE" ]; then
    echo "Adding LLM_API_BASE and OPENAI_API_BASE to environment variables"
    ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"LLM_API_BASE\", \"value\": \"$OPENAI_API_BASE\"}, {\"name\": \"OPENAI_API_BASE\", \"value\": \"$OPENAI_API_BASE\"}]")
fi

if [ -n "$MODEL_NAME" ]; then
    echo "Adding LLM_MODEL and EXGENTIC_SET_AGENT_MODEL to environment variables"
    ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"LLM_MODEL\", \"value\": \"$MODEL_NAME\"}, {\"name\": \"EXGENTIC_SET_AGENT_MODEL\", \"value\": \"$MODEL_NAME\"}]")
fi

# If agent is tool_calling, enable short listing
if [ "$AGENT_NAME_INPUT" = "tool_calling" ]; then
    echo "Adding EXGENTIC_SET_AGENT_ENABLE_TOOL_SHORTLISTING=true for tool_calling agent"
    ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"EXGENTIC_SET_AGENT_ENABLE_TOOL_SHORTLISTING\", \"value\": \"true\"}]")
fi

# Add EXGENTIC_OTEL_ENABLED, OTEL_EXPORTER_OTLP_ENDPOINT, and OTEL_EXPORTER_OTLP_PROTOCOL.
# The kagenti-deps otel-collector binds OTLP/HTTP on 8335 (and gRPC on 4317);
# nothing is listening on 4318, so requests there return 503 and crash the
# agent's strict OTEL startup probe.
echo "Adding EXGENTIC_OTEL_ENABLED, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL"
ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"EXGENTIC_OTEL_ENABLED\", \"value\": \"true\"}, {\"name\": \"OTEL_EXPORTER_OTLP_ENDPOINT\", \"value\": \"http://otel-collector.kagenti-system.svc.cluster.local:8335\"}, {\"name\": \"OTEL_EXPORTER_OTLP_PROTOCOL\", \"value\": \"http/protobuf\"}]")

# Set agent runner to thread for in-process execution (avoids venv subprocess overhead)
echo "Adding EXGENTIC_DEFAULT_RUNNER=thread for agent"
ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"EXGENTIC_DEFAULT_RUNNER\", \"value\": \"thread\"}]")

echo "✓ Environment variables prepared for deployment"
echo ""

# Step 8: Deploy agent via Kagenti API
echo "Step 8: Deploying agent via Kagenti API..."

# IBAC patches the operator-injected authbridge sidecar's plugin pipeline, so the
# operator must inject one in the first place. Without authBridgeEnabled, no
# authbridge-config-<agent> ConfigMap is created and apply-ibac.sh has nothing to patch.
AUTHBRIDGE_ENABLED="false"
if [ "$USE_IBAC" = "true" ]; then
    AUTHBRIDGE_ENABLED="true"
fi

if [ "$DEPLOYMENT_TYPE" = "source" ]; then
    # Deploy generic agent from source
    AGENT_JSON=$(cat <<EOF
{
  "name": "$AGENT_NAME",
  "namespace": "$NAMESPACE",
  "gitUrl": "https://github.com/kagenti/agent-examples",
  "gitPath": "a2a/generic_agent",
  "gitBranch": "main",
  "imageTag": "latest",
  "protocol": "a2a",
  "framework": "custom",
  "deploymentMethod": "source",
  "workloadType": "deployment",
  "envVars": $ENV_VARS_WITH_CONFIG,
  "servicePorts": [
    {
      "name": "http",
      "port": 8080,
      "targetPort": 8000,
      "protocol": "TCP"
    }
  ],
  "createHttpRoute": false,
  "authBridgeEnabled": $AUTHBRIDGE_ENABLED,
  "spireEnabled": false
}
EOF
)
else
    # Deploy exgentic agent from image
    AGENT_JSON=$(cat <<EOF
{
  "name": "$AGENT_NAME",
  "namespace": "$NAMESPACE",
  "gitUrl": "",
  "gitPath": "",
  "gitBranch": "",
  "imageTag": "$IMAGE_TAG",
  "protocol": "a2a",
  "framework": "custom",
  "deploymentMethod": "image",
  "containerImage": "$IMAGE_NAME",
  "workloadType": "deployment",
  "envVars": $ENV_VARS_WITH_CONFIG,
  "servicePorts": [
    {
      "name": "http",
      "port": 8080,
      "targetPort": 8000,
      "protocol": "TCP"
    }
  ],
  "createHttpRoute": false,
  "authBridgeEnabled": $AUTHBRIDGE_ENABLED,
  "spireEnabled": false
}
EOF
)
fi

echo "Agent configuration:"
echo "$AGENT_JSON" | jq '.'
echo ""

HTTP_CODE=$(curl -s --max-time 30 -w "%{http_code}" -o /tmp/kagenti_agent_response.txt -X POST "$KAGENTI_API/api/v1/agents" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$AGENT_JSON") || true

RESPONSE=$(cat /tmp/kagenti_agent_response.txt)

echo "API Response (HTTP $HTTP_CODE):"
echo "$RESPONSE"
echo ""

if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "Error: Could not connect to Kagenti API at $KAGENTI_API"
    echo "Please ensure the port-forward to kagenti-backend is running:"
    echo "  kubectl port-forward -n kagenti-system svc/kagenti-backend $KAGENTI_PORT:8000"
    exit 1
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "✓ Agent deployment successful"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "✓ Agent already exists (HTTP 409)"
else
    echo "Error: Kagenti API deployment failed with HTTP $HTTP_CODE"
    exit 1
fi

echo ""

# Step 9: Wait for build to complete (only for source deployments)
if [ "$DEPLOYMENT_TYPE" = "source" ]; then
    echo "Step 9: Waiting for build to complete..."
    BUILD_RUN_NAME=$(echo "$RESPONSE" | jq -r '.message' | grep -o "BuildRun: '[^']*'" | sed "s/BuildRun: '\([^']*\)'/\1/")
    
    if [ -z "$BUILD_RUN_NAME" ]; then
        echo "Warning: Could not extract BuildRun name from response"
        echo "Response: $RESPONSE"
        echo "Skipping build wait"
    else
        echo "Monitoring BuildRun: $BUILD_RUN_NAME"
        
        # Wait up to 5 minutes for build to complete
        for i in {1..60}; do
            BUILD_STATUS=$(kubectl get buildrun "$BUILD_RUN_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "Unknown")
            BUILD_REASON=$(kubectl get buildrun "$BUILD_RUN_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo "Unknown")
            
            if [ "$BUILD_STATUS" = "True" ]; then
                echo "✓ Build completed successfully"
                break
            elif [ "$BUILD_STATUS" = "False" ]; then
                echo "✗ Build failed with reason: $BUILD_REASON"
                echo "Check logs with: kubectl logs -n $NAMESPACE -l buildrun.shipwright.io/name=$BUILD_RUN_NAME"
                exit 1
            fi
            
            echo "  Build in progress... ($i/60)"
            sleep 5
        done
        
        if [ "$BUILD_STATUS" != "True" ]; then
            echo "✗ Build did not complete within 5 minutes"
            exit 1
        fi
    fi
    echo ""
else
    # For image deployments, patch imagePullPolicy
    echo "Step 9: Patching imagePullPolicy to IfNotPresent..."
    sleep 2  # Give the deployment a moment to be created
    kubectl patch deployment $AGENT_NAME -n $NAMESPACE -p '{"spec":{"template":{"spec":{"containers":[{"name":"agent","imagePullPolicy":"IfNotPresent"}]}}}}' 2>/dev/null || echo "Warning: Could not patch imagePullPolicy"
    echo "✓ ImagePullPolicy patched"
    echo ""
fi

# Step 10: Wait for agent deployment to be created and ready
echo "Step 10: Waiting for agent deployment to be created..."

# Wait for deployment to be created (up to 2 minutes)
for i in {1..24}; do
    if kubectl get deployment $AGENT_NAME -n $NAMESPACE >/dev/null 2>&1; then
        echo "✓ Agent deployment created"
        break
    fi
    echo "  Waiting for deployment to be created... ($i/24)"
    sleep 5
done

# Check if deployment exists
if ! kubectl get deployment $AGENT_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "✗ Agent deployment was not created within 2 minutes"
    exit 1
fi

echo "Waiting for agent deployment to be ready..."
kubectl wait --for=condition=available deployment/$AGENT_NAME -n $NAMESPACE --timeout=120s

if [ $? -ne 0 ]; then
    echo "✗ Agent deployment did not become ready"
    exit 1
fi

echo "✓ Agent deployment is ready"
echo ""

# Step 11: Update openai-secret
echo "=========================================="
echo "Final Configuration"
echo "=========================================="
echo ""

# Step 11.1: Update the openai-secret with current OPENAI_API_KEY
echo "Step 11.1: Updating openai-secret with OPENAI_API_KEY..."

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
    ]" 2>/dev/null && echo "✓ Secret updated" || echo "Warning: Could not update secret"
fi

echo ""

# Step 11.2: Set resource limits
echo "Step 11.2: Setting resource limits..."

# Set CPU limit to 4 cores and memory limit to 3GB
kubectl set resources deployment/$AGENT_NAME -n $NAMESPACE \
    --limits=cpu=4,memory=2Gi \
    --requests=cpu=500m,memory=512Mi 2>/dev/null && echo "✓ Agent resource limits set (CPU: 4 cores, Memory: 3Gi)" || echo "Warning: Could not set resource limits"

echo ""

# Step 11.3: Wait for deployment to stabilize
echo "Step 11.3: Waiting for deployment to stabilize..."
kubectl rollout status deployment/$AGENT_NAME -n $NAMESPACE --timeout=120s
echo "✓ Deployment stable"
echo ""

# Step 11.4: Optionally inject IBAC sidecar overlay
if [ "$USE_IBAC" = "true" ]; then
    echo "Step 11.4: Applying IBAC overlay..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ ! -x "$SCRIPT_DIR/ibac/apply-ibac.sh" ]; then
        echo "Error: $SCRIPT_DIR/ibac/apply-ibac.sh not found or not executable"
        exit 1
    fi
    AGENT_NAME="$AGENT_NAME" NAMESPACE="$NAMESPACE" \
        OPENAI_API_BASE="${OPENAI_API_BASE:-}" \
        IBAC_JUDGE_ENDPOINT="${IBAC_JUDGE_ENDPOINT:-}" \
        IBAC_JUDGE_MODEL="${IBAC_JUDGE_MODEL:-}" \
        IBAC_AGENT_LLM_HOST="${IBAC_AGENT_LLM_HOST:-}" \
        IBAC_TIMEOUT_MS="${IBAC_TIMEOUT_MS:-}" \
        "$SCRIPT_DIR/ibac/apply-ibac.sh"
    echo ""
fi

# Step 12: Test agent card access
echo "Step 12: Testing agent card access..."

# Check if service exists
if ! kubectl get svc $AGENT_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠ Service $AGENT_NAME not found, skipping card test"
else
    # Set up port-forward to agent
    AGENT_PORT=8084
    
    # Check if port is already in use
    if nc -z localhost $AGENT_PORT 2>/dev/null; then
        echo "⚠ Port $AGENT_PORT already in use, skipping card test"
    else
        # Retry until agent responds (up to 60s)
        # After a rollout, the new pod's endpoint may not be registered yet,
        # causing port-forward to exit immediately. Restart it on each attempt.
        CARD_RESPONSE=""
        AGENT_PF_PID=""
        for i in $(seq 1 60); do
            # (Re)start port-forward if it's not running
            if [ -z "$AGENT_PF_PID" ] || ! kill -0 $AGENT_PF_PID 2>/dev/null; then
                [ -n "$AGENT_PF_PID" ] && { kill $AGENT_PF_PID 2>/dev/null || true; wait $AGENT_PF_PID 2>/dev/null || true; }
                kubectl port-forward -n $NAMESPACE svc/$AGENT_NAME $AGENT_PORT:8080 >/dev/null 2>&1 &
                AGENT_PF_PID=$!
                sleep 2
            fi

            CARD_RESPONSE=$(curl -s --max-time 3 http://localhost:$AGENT_PORT/.well-known/agent-card.json 2>/dev/null) || true
            if [ -n "$CARD_RESPONSE" ]; then
                break
            fi
            if [ $((i % 10)) -eq 0 ]; then
                echo "  Waiting for agent to be ready... (${i}s)"
            fi
            sleep 1
        done

        # Always clean up port-forward
        if [ -n "$AGENT_PF_PID" ]; then
            kill $AGENT_PF_PID 2>/dev/null || true
            wait $AGENT_PF_PID 2>/dev/null || true
        fi

            if [ -z "$CARD_RESPONSE" ]; then
                echo "⚠ No response from agent card endpoint after 60s"
                echo "  Agent is deployed and running, but card endpoint did not respond"
            else
                # Check if response contains error
                if echo "$CARD_RESPONSE" | grep -q '"error"'; then
                    echo "⚠ Agent responded with error:"
                    echo "$CARD_RESPONSE" | jq '.' 2>/dev/null || echo "$CARD_RESPONSE"
                else
                    echo "✓ Agent card access successful:"
                    echo "$CARD_RESPONSE" | jq '.name, .description' 2>/dev/null || echo "$CARD_RESPONSE"
                fi
            fi
        fi
fi

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Agent configuration:"
echo "  Deployment: $AGENT_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Service: $AGENT_NAME.$NAMESPACE:8080"
echo "  Tool: $TOOL_NAME.$NAMESPACE:8000"
echo "  Model: $MODEL_NAME"
echo "  CPU Limit: 4 cores"
echo "  Memory Limit: 3Gi"
echo "  IBAC: $USE_IBAC"
if [ -n "$OPENAI_API_BASE" ]; then
    echo "  LLM_API_BASE: $OPENAI_API_BASE"
    echo "  OPENAI_API_BASE: $OPENAI_API_BASE"
    echo "  LLM_MODEL: $MODEL_NAME"
    echo "  EXGENTIC_SET_AGENT_MODEL: $MODEL_NAME"
    if [ -n "$OPENAI_API_KEY" ]; then
        echo "  OPENAI_API_KEY: (updated from env var)"
    fi
fi
echo ""
echo "Agent is ready and accessible!"
echo ""

# Made with Bob
