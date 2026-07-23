#!/bin/bash
# Deploy and Configure agent to Rossoctl cluster via API
# Usage: ./deploy-agent.sh --benchmark <name> --agent <name> [OPTIONS]
# Example: ./deploy-agent.sh --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini
# Example: ./deploy-agent.sh --benchmark tau2 --agent tool_calling --openshift apps.mycluster.example.com

set -e

# Auto-load .env from the script's directory so values like
# IBAC_JUDGE_ENDPOINT / IBAC_JUDGE_MODEL flow through to apply-pipeline.sh
# without the caller having to `source .env` first. Existing shell exports
# take precedence — only unset vars are populated from .env.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blanks and comments
        [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip optional leading "export "
        line="${line#export }"
        # Must look like KEY=VALUE
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        # Strip surrounding single or double quotes from the value
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        # Only set if not already in the environment (shell wins over .env)
        if [ -z "${!key+x}" ]; then
            export "$key=$val"
        fi
    done <"$ENV_FILE"
fi

# Default values — env vars take precedence (allows injection via Kubernetes Job secrets)
MODEL_NAME="Azure/gpt-4.1"
KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-unknown}"
BENCHMARK_NAME=""
AGENT_NAME_INPUT=""
EXPERIMENT_NAME="default"
USE_MCP_GATEWAY="false"
USE_LOCAL_IMAGE="false"
CLUSTER_MODE=""

# AuthBridge plugin pipeline composition. See AUTHBRIDGE_PIPELINE_SPEC.md.
# PIPELINE_PRESET is set by --plugin-preset; PIPELINE_SELECTORS accumulates
# --plugin / --no-plugin args in order. PIPELINE_OVERLAY_FILE is set by
# --plugin-config-file. The sidecar is injected when ANY of these are set.
PIPELINE_PRESET=""
PIPELINE_SELECTORS=()
PIPELINE_OVERLAY_FILE=""

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
        --use-mcp-gateway)
            USE_MCP_GATEWAY="true"
            shift
            ;;
        --local-image)
            USE_LOCAL_IMAGE="true"
            shift
            ;;
        --plugin)
            PIPELINE_SELECTORS+=("+$2")
            shift 2
            ;;
        --no-plugin)
            PIPELINE_SELECTORS+=("-$2")
            shift 2
            ;;
        --plugin-preset)
            PIPELINE_PRESET="$2"
            shift 2
            ;;
        --plugin-config-file)
            PIPELINE_OVERLAY_FILE="$2"
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
            echo "  --agent NAME               Agent name (e.g., tool_calling)"
            echo ""
            echo "Optional Arguments:"
            echo "  --experiment NAME          Experiment name suffix appended to pod names (default: default)"
            echo "  --model MODEL              Model name (default: Azure/gpt-4.1)"
            echo "  --keycloak-user USER       Keycloak username (default: admin)"
            echo "  --keycloak-pass PASS       Keycloak password (auto-detected from cluster if not provided)"
            echo "  --use-mcp-gateway          Connect agent to MCP Gateway instead of direct MCP server"
            echo "  --local-image              Use locally built image instead of pulling from registry"
            echo "  --kind                     Target a local Kind cluster (default)"
            echo "  --openshift DOMAIN         Target an OpenShift cluster with the given ingress domain"
            echo "  --in-cluster               Running as a Kubernetes Job inside the cluster"
            echo ""
            echo "AuthBridge plugin pipeline (see AUTHBRIDGE_PIPELINE_SPEC.md):"
            echo "  --plugin-preset PRESET     Named bundle: auth-only | ibac-only | full"
            echo "  --plugin NAME[:POLICY]     Enable plugin; POLICY ∈ {enforce(default), observe, off}; repeatable"
            echo "  --no-plugin NAME           Shorthand for --plugin NAME:off; repeatable"
            echo "  --plugin-config-file PATH  Flat-map YAML overlay merged after selectors"
            echo "  -h, --help                 Show this help message"
            echo ""
            echo "Plugin names: jwt-validation, token-exchange, token-broker, a2a-parser,"
            echo "              mcp-parser, inference-parser, ibac"
            echo ""
            echo "Plugin tunables (consumed when the named plugin is in the active set):"
            echo "  IBAC_JUDGE_ENDPOINT          Judge LLM base URL (default: http://host.docker.internal:11434)"
            echo "  IBAC_JUDGE_MODEL             Judge model id (default: llama3.2:3b)"
            echo "  IBAC_AGENT_LLM_HOST          Hostname of the agent's own LLM (auto-derived from OPENAI_API_BASE)"
            echo "  IBAC_TIMEOUT_MS              Per-judge-call timeout in ms (default: 15000)"
            echo "  TOKEN_BROKER_URL             Broker URL (token-broker plugin)"
            echo "  TOKEN_BROKER_AUDIENCE        Broker audience (token-broker plugin)"
            echo ""
            echo "Examples:"
            echo "  $0 --benchmark tau2 --agent tool_calling --model Azure/gpt-4o-mini"
            echo "  $0 --benchmark tau2 --agent tool_calling --use-mcp-gateway"
            echo "  $0 --benchmark tau2 --agent tool_calling --plugin-preset auth-only"
            echo "  $0 --benchmark tau2 --agent tool_calling --plugin-preset full --plugin ibac:observe"
            echo "  $0 --benchmark tau2 --agent tool_calling --plugin jwt-validation --plugin token-exchange"
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

# Determine agent name and image
# Automatically add exgentic-a2a- prefix if not already present
if [[ "$AGENT_NAME_INPUT" == exgentic-a2a-* ]]; then
    FULL_AGENT_NAME="$AGENT_NAME_INPUT"
else
    FULL_AGENT_NAME="exgentic-a2a-${AGENT_NAME_INPUT}"
fi
# Replace underscores with hyphens for Kubernetes compatibility
AGENT_NAME="${FULL_AGENT_NAME}-${BENCHMARK_NAME}"
AGENT_NAME="${AGENT_NAME//_/-}"
# Append experiment suffix when non-default so parallel experiments get distinct pod names
if [ -n "$EXPERIMENT_NAME" ] && [ "$EXPERIMENT_NAME" != "default" ]; then
    EXPERIMENT_SUFFIX="${EXPERIMENT_NAME//_/-}"
    AGENT_NAME="${AGENT_NAME}-${EXPERIMENT_SUFFIX}"
fi

# Default to Exgentic registry, can be overridden with environment variable
EXGENTIC_REGISTRY="${EXGENTIC_REGISTRY:-ghcr.io/exgentic}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
REMOTE_IMAGE_NAME="${EXGENTIC_REGISTRY}/${FULL_AGENT_NAME}:${IMAGE_TAG}"

TOOL_NAME="exgentic-mcp-${BENCHMARK_NAME}"
# Match the experiment suffix applied to the benchmark so MCP_URL points to the right service
if [ -n "$EXPERIMENT_NAME" ] && [ "$EXPERIMENT_NAME" != "default" ]; then
    TOOL_NAME="${TOOL_NAME}-${EXPERIMENT_SUFFIX}"
fi
NAMESPACE="${NAMESPACE:-team1}"

# Load shared URL helpers (rossoctl_api_url, keycloak_api_url, agent_http_url, …)
export CLUSTER_MODE INGRESS_DOMAIN
# shellcheck source=libsh/urls.sh
source "$SCRIPT_DIR/libsh/urls.sh"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
# shellcheck source=libsh/check-kubectl-context.sh
source "$SCRIPT_DIR/libsh/check-kubectl-context.sh"
check_kubectl_context

ROSSOCTL_API="$(rossoctl_api_url)"
KEYCLOAK_API="$(keycloak_api_url)"

echo "=========================================="
echo "Deploying Exgentic Agent: $AGENT_NAME"
echo "From image: $REMOTE_IMAGE_NAME"
echo "Model: $MODEL_NAME"
echo "=========================================="
echo ""

# Step 0: Sync local image to cluster
if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    echo "Step 0: Syncing local image to cluster..."
    export REMOTE_IMAGE_NAME KIND_CLUSTER_NAME="rossoctl"
    source "$(dirname "$0")/sync-image-to-cluster.sh"
else
    echo "Step 0: Syncing local image to cluster... (skipped, K8s will pull from remote registry)"
fi

IMAGE_NAME="$REMOTE_IMAGE_NAME"
echo ""

# Step 1: Verify Keycloak is accessible
echo "Step 1: Verifying Keycloak is accessible at $KEYCLOAK_API..."
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

# Step 1.5: Auto-fetch Keycloak password from cluster if using default
if [ "$KEYCLOAK_PASSWORD" = "unknown" ]; then
    echo "Step 1.5: Attempting to fetch Keycloak password from cluster..."
    
    # Try to get rossoctl realm admin credentials from rossoctl-test-user secret
    ROSSOCTL_PASSWORD=$(kubectl get secret rossoctl-test-user -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$ROSSOCTL_PASSWORD" ]; then
        # Test if the fetched password works
        TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=admin" \
            -d "password=$ROSSOCTL_PASSWORD" \
            -d "grant_type=password" \
            -d "client_id=rossoctl" 2>/dev/null || echo "")
        
        if echo "$TEST_AUTH" | grep -q "access_token"; then
            KEYCLOAK_PASSWORD="$ROSSOCTL_PASSWORD"
            echo "✓ Successfully fetched and verified Keycloak password from cluster"
        else
            echo "⚠ Warning: Fetched password from cluster but authentication failed"
            echo "Please provide the correct password using --keycloak-pass option"
            exit 1
        fi
    else
        # Fallback: test if default password works
        TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=admin" \
            -d "password=admin" \
            -d "grant_type=password" \
            -d "client_id=rossoctl" 2>/dev/null || echo "")
        
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

# Step 2: Enable Direct Access Grants for rossoctl client if needed
echo "Step 2: Enabling Direct Access Grants for rossoctl client..."

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
        # Get rossoctl client configuration
        CLIENT_CONFIG=$(curl -s "$KEYCLOAK_API/admin/realms/rossoctl/clients?clientId=rossoctl" \
            -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null)
        
        CLIENT_ID=$(echo "$CLIENT_CONFIG" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"\([^"]*\)"/\1/')
        
        if [ -n "$CLIENT_ID" ]; then
            # Enable direct access grants
            curl -s -X PUT "$KEYCLOAK_API/admin/realms/rossoctl/clients/$CLIENT_ID" \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{"directAccessGrantsEnabled": true}' >/dev/null 2>&1
            echo "✓ Direct access grants enabled for rossoctl client"
        fi
    fi
fi

echo ""

# Step 2.5: Verify Keycloak password works now that Direct Access Grants is enabled
echo "Step 2.5: Verifying Keycloak authentication..."
TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=rossoctl" 2>/dev/null || echo "")

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
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=rossoctl" || echo "TOKEN_ERROR")

if [ "$TOKEN_RESPONSE" = "TOKEN_ERROR" ]; then
    echo "Error: Failed to get authentication token from Keycloak"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    echo ""
    echo "If you see 'unauthorized_client' error, the rossoctl client may need Direct Access Grants enabled."
    echo "You can enable it manually in Keycloak admin console or run this script again."
    exit 1
fi

echo "✓ Successfully obtained authentication token"

echo ""

# Step 4: Verify Rossoctl backend is accessible
echo "Step 4: Verifying Rossoctl backend accessibility at $ROSSOCTL_API..."
ROSSOCTL_REACHABLE=false
for i in $(seq 1 10); do
    if curl -s --max-time 5 "$ROSSOCTL_API/api/v1/namespaces" >/dev/null 2>&1; then
        echo "✓ Rossoctl backend is accessible"
        ROSSOCTL_REACHABLE=true
        break
    fi
    sleep 1
done

if [ "$ROSSOCTL_REACHABLE" = false ]; then
    echo "Error: Rossoctl backend is not accessible at $ROSSOCTL_API after 10s"
    echo "Please ensure Rossoctl backend is reachable via HTTP route"
    exit 1
fi

echo ""

# Step 5: Delete existing agent if it exists
echo "Step 5: Deleting existing agent via Rossoctl API if it exists..."
DELETE_RESPONSE=$(curl -s --max-time 10 -w "%{http_code}" -o /tmp/rossoctl_delete_agent_response.txt -X DELETE "$ROSSOCTL_API/api/v1/agents/$NAMESPACE/$AGENT_NAME" \
    -H "Authorization: Bearer $ACCESS_TOKEN") || true

if [ -z "$DELETE_RESPONSE" ] || [ "$DELETE_RESPONSE" = "000" ]; then
    echo "Error: Could not connect to Rossoctl API at $ROSSOCTL_API"
    echo "Please ensure Rossoctl backend is accessible via HTTP route"
    exit 1
elif [ "$DELETE_RESPONSE" = "200" ] || [ "$DELETE_RESPONSE" = "404" ]; then
    echo "✓ Agent deleted or did not exist (HTTP $DELETE_RESPONSE)"

    if [ "$DELETE_RESPONSE" = "200" ]; then
        echo "Step 5a: Waiting for Rossoctl to finish removing the old agent record..."
        GONE_WAIT=0
        GONE_MAX=30
        while true; do
            CHECK_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
                "$ROSSOCTL_API/api/v1/agents/$NAMESPACE/$AGENT_NAME" \
                -H "Authorization: Bearer $ACCESS_TOKEN") || CHECK_CODE="000"
            if [ "$CHECK_CODE" = "404" ]; then
                echo "✓ Agent record confirmed gone (HTTP 404)"
                break
            fi
            if [ $GONE_WAIT -ge $GONE_MAX ]; then
                echo "Error: Agent record still present after ${GONE_MAX}s — Rossoctl cleanup stalled" >&2
                exit 1
            fi
            sleep 2
            GONE_WAIT=$((GONE_WAIT + 2))
        done
    fi
else
    # Any other status (e.g. 503 upstream/connection errors, 401/403) means the
    # Rossoctl API is broken or unreachable. Fail fast here rather than warn and
    # continue into later steps that all hit the same dead backend.
    echo "Error: Delete returned HTTP $DELETE_RESPONSE" >&2
    echo "  Endpoint: $ROSSOCTL_API/api/v1/agents/$NAMESPACE/$AGENT_NAME" >&2
    echo "  Response: $(cat /tmp/rossoctl_delete_response.txt)" >&2
    echo "  The Rossoctl API is not healthy; aborting deployment." >&2
    exit 1
fi

echo ""

# Step 6: Fetch and parse environment variables
echo "Step 6: Fetching environment variables..."

ENV_FILE_URL="https://raw.githubusercontent.com/yoavkatz/agent-examples/refs/heads/feature/exgentic-mcp-server/a2a/exgentic_agent/.env.example"

ENV_CONTENT=$(curl -s "$ENV_FILE_URL")

if [ -z "$ENV_CONTENT" ] || echo "$ENV_CONTENT" | grep -q "404: Not Found"; then
    echo "Error: Could not fetch env file"
    echo "Expected file: $ENV_FILE_URL"
    exit 1
fi

# Parse env vars using the Rossoctl API
ENV_PARSE_RESPONSE=$(curl -s --max-time 10 -X POST "$ROSSOCTL_API/api/v1/agents/parse-env" \
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

# Add MCP_URL to environment variables
if [ "$USE_MCP_GATEWAY" = "true" ]; then
    MCP_URL="$(mcp_gateway_url)/mcp"
    echo "Using MCP Gateway URL: $MCP_URL"
else
    MCP_URL="$(tool_k8s_url "$TOOL_NAME" "$NAMESPACE")/mcp"
    echo "Using MCP service URL: $MCP_URL"
fi

ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS" | jq ". + [{\"name\": \"MCP_URL\", \"value\": \"$MCP_URL\"}]")

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

# The rossoctl-deps otel-collector listens for OTLP/HTTP on 8335 (and gRPC on
# 4317). The receivers ConfigMap shows 4318, but the running collector startup
# logs ("Starting HTTP server endpoint: 0.0.0.0:8335") confirm 8335 is what's
# actually bound. Working sibling pods (e.g. tau2) also export to 8335.
echo "Adding EXGENTIC_OTEL_ENABLED, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL"
ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"EXGENTIC_OTEL_ENABLED\", \"value\": \"true\"}, {\"name\": \"OTEL_EXPORTER_OTLP_ENDPOINT\", \"value\": \"http://otel-collector.rossoctl-system.svc.cluster.local:8335\"}, {\"name\": \"OTEL_EXPORTER_OTLP_PROTOCOL\", \"value\": \"http/protobuf\"}]")

# Set agent runner to thread for in-process execution (avoids venv subprocess overhead)
echo "Adding EXGENTIC_DEFAULT_RUNNER=thread for agent"
ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"EXGENTIC_DEFAULT_RUNNER\", \"value\": \"thread\"}]")

# Force litellm to use its bundled model-pricing JSON instead of fetching
# https://raw.githubusercontent.com/BerriAI/litellm/.../model_prices_and_context_window.json
# at startup. The remote fetch happens before any inbound request, so IBAC
# rejects it with `ibac.no_session` / `ibac.no_intent`.
echo "Adding LITELLM_LOCAL_MODEL_COST_MAP=True"
ENV_VARS_WITH_CONFIG=$(echo "$ENV_VARS_WITH_CONFIG" | jq ". + [{\"name\": \"LITELLM_LOCAL_MODEL_COST_MAP\", \"value\": \"True\"}]")

echo "✓ Environment variables prepared for deployment"
echo ""

# Step 8: Deploy agent via Rossoctl API
echo "Step 8: Deploying agent via Rossoctl API..."

# Resolve the AuthBridge plugin pipeline from --plugin-preset, --plugin,
# --no-plugin, and --plugin-config-file flags. The sidecar is injected
# (authBridgeEnabled=true in the operator API call) when ANY of these
# selectors are supplied. Resolution algorithm: AUTHBRIDGE_PIPELINE_SPEC.md §4.3.
#
# Resolution is delegated to a Python helper because macOS ships bash 3.2
# (no associative arrays); the helper validates selectors, reads the
# preset YAML, applies last-write-wins ordering, runs the mutex check,
# and emits the resolved PIPELINE_PLUGINS string.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Sidecar injection trigger: any selector means inject.
if [ -n "$PIPELINE_PRESET" ] || [ ${#PIPELINE_SELECTORS[@]} -gt 0 ] || [ -n "$PIPELINE_OVERLAY_FILE" ]; then
    AUTHBRIDGE_ENABLED="true"
else
    AUTHBRIDGE_ENABLED="false"
fi

PIPELINE_PLUGINS=""
if [ "$AUTHBRIDGE_ENABLED" = "true" ]; then
    PIPELINE_PLUGINS=$(
        PIPELINE_PRESET="$PIPELINE_PRESET" \
        PRESETS_DIR="$SCRIPT_DIR/authbridge/presets" \
        python3 - "${PIPELINE_SELECTORS[@]}" <<'PYEOF'
import os, sys
import yaml

KNOWN = ["jwt-validation", "token-exchange", "token-broker",
         "a2a-parser", "mcp-parser", "inference-parser", "ibac"]
VALID = ("enforce", "observe", "off")
CHAIN = {p: ("inbound" if p in ("a2a-parser", "jwt-validation") else "outbound")
         for p in KNOWN}

def die(msg):
    print(f"Error: {msg}", file=sys.stderr); sys.exit(1)

resolved = {}

preset = os.environ.get("PIPELINE_PRESET", "")
if preset:
    pdir = os.environ.get("PRESETS_DIR", "")
    pfile = os.path.join(pdir, f"{preset}.yaml")
    if not os.path.isfile(pfile):
        die(f"unknown preset '{preset}' (looked for {pfile}); available: auth-only, ibac-only, full")
    with open(pfile) as f:
        d = yaml.safe_load(f) or {}
    for chain in ("inbound", "outbound"):
        for name in d.get(chain, []) or []:
            if name not in KNOWN:
                die(f"preset {preset} references unknown plugin '{name}'")
            resolved[name] = "enforce"

for sel in sys.argv[1:]:
    if not sel:
        continue
    op, rest = sel[0], sel[1:]
    if op == "+":
        if ":" in rest:
            name, policy = rest.split(":", 1)
        else:
            name, policy = rest, "enforce"
        if name not in KNOWN:
            die(f"--plugin: unknown plugin '{name}'. Known: {' '.join(KNOWN)}")
        if policy not in VALID:
            die(f"--plugin: unknown policy '{policy}' for '{name}'. Valid: {', '.join(VALID)}")
        resolved[name] = policy
    elif op == "-":
        if rest not in KNOWN:
            die(f"--no-plugin: unknown plugin '{rest}'. Known: {' '.join(KNOWN)}")
        resolved[rest] = "off"
    else:
        die(f"internal: unrecognized selector '{sel}'")

# Mutex: token-exchange and token-broker on the outbound chain.
te = resolved.get("token-exchange", "off")
tb = resolved.get("token-broker", "off")
if te != "off" and tb != "off":
    die("token-exchange and token-broker are mutually exclusive "
        "(both claim ClaimAuthorizationHeader). Disable one.")

tokens = []
for name in KNOWN:
    policy = resolved.get(name, "off")
    if policy == "off":
        continue
    tokens.append(name if policy == "enforce" else f"{name}:{policy}")
print(" ".join(tokens))
PYEOF
    ) || exit 1
fi

# Step 7.5: Bake OTEL-collector skip_hosts into the NAMESPACE authbridge base
# BEFORE the agent is created, so the sidecar has it from first pod boot — no
# post-deploy patch of the running agent, no reload race.
#
# Why the namespace base and not the per-agent ConfigMap: the rossoctl operator
# webhook force-overwrites `authbridge-config-<agent>` (server-side apply,
# ForceOwnership) on every pod admission, so a per-agent pre-seed can't survive.
# The one thing it does honor is the namespace-level `authbridge-runtime-config`
# `config.yaml`, which it reads as the base and MERGES into each per-agent CM —
# it only injects reverse_proxy_addr / reverse_proxy_backend / forward_proxy_addr
# into `listener`, so a `listener.skip_hosts` we add here rides through untouched.
#
# NOTE: `skip_hosts` is an AuthBridge-*binary* listener key; it is not defined in
# rossoctl/operator source and has NOT been verified against the sidecar's config
# schema. If the sidecar rejects the merged config, look for a "reload failed" /
# parse error in the sidecar container logs
# (kubectl -n "$NAMESPACE" logs deploy/<agent> -c authbridge  # or authbridge-proxy / envoy-proxy)
# and correct the key name/shape below. This edit is namespace-wide and persists
# for every agent in $NAMESPACE.
if [ "$AUTHBRIDGE_ENABLED" = "true" ] && [ "$CLUSTER_MODE" != "in-cluster" ]; then
    echo "Step 7.5: Adding OTEL-collector skip_hosts to namespace authbridge base..."
    NS_AB_CM="authbridge-runtime-config"

    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
        echo "Error: python3 with PyYAML is required to merge skip_hosts into $NS_AB_CM." >&2
        echo "  Install with one of:" >&2
        echo "    pip3 install --user pyyaml" >&2
        echo "    brew install libyaml && pip3 install pyyaml      # macOS" >&2
        echo "    sudo apt install python3-yaml                    # Debian/Ubuntu" >&2
        exit 1
    elif ! kubectl -n "$NAMESPACE" get configmap "$NS_AB_CM" >/dev/null 2>&1; then
        echo "Error: ConfigMap $NAMESPACE/$NS_AB_CM not found." >&2
        echo "  The operator/Helm owns this base; it must exist before deploying an" >&2
        echo "  AuthBridge-enabled agent. We do not fabricate one here (that would drop" >&2
        echo "  the pipeline: block and break auth). Ensure the namespace is provisioned." >&2
        exit 1
    else
        CURRENT_NS_YAML=$(
            kubectl -n "$NAMESPACE" get configmap "$NS_AB_CM" \
                -o jsonpath='{.data.config\.yaml}'
        )
        MERGED_NS_YAML=$(printf '%s' "$CURRENT_NS_YAML" | python3 - <<'PYEOF'
import sys
import yaml

# Hosts the sidecar must NOT intercept (OTEL collector, rossoctl-system).
SKIP_HOSTS = [
    "otel-collector.rossoctl-system.svc.cluster.local",
    "otel-collector",
]

cfg = yaml.safe_load(sys.stdin.read()) or {}
listener = cfg.get("listener")
if not isinstance(listener, dict):
    listener = {}
existing = listener.get("skip_hosts")
if not isinstance(existing, list):
    existing = []
# Union + sort + de-dupe so re-runs are byte-stable and we don't clobber
# hosts someone else added.
listener["skip_hosts"] = sorted(set(existing) | set(SKIP_HOSTS))
cfg["listener"] = listener
# sort_keys=True keeps output deterministic across runs for the no-op check.
sys.stdout.write(yaml.safe_dump(cfg, default_flow_style=False, sort_keys=True))
PYEOF
        ) || { echo "Error: skip_hosts merge failed for $NAMESPACE/$NS_AB_CM (bad YAML in config.yaml?)" >&2; exit 1; }

        if [ -z "$MERGED_NS_YAML" ]; then
            echo "Error: skip_hosts merge produced empty output for $NAMESPACE/$NS_AB_CM" >&2
            exit 1
        elif [ "$CURRENT_NS_YAML" = "$MERGED_NS_YAML" ]; then
            echo "✓ Namespace authbridge base already has skip_hosts — nothing to patch"
        else
            TMP_NS_CONFIG=$(mktemp)
            printf '%s' "$MERGED_NS_YAML" >"$TMP_NS_CONFIG"
            # Conflict-free create --dry-run | apply (same pattern as apply-pipeline.sh).
            if kubectl -n "$NAMESPACE" create configmap "$NS_AB_CM" \
                --from-file=config.yaml="$TMP_NS_CONFIG" \
                --dry-run=client -o yaml \
                | kubectl -n "$NAMESPACE" apply -f - >/dev/null; then
                echo "✓ skip_hosts added to $NAMESPACE/$NS_AB_CM"
                rm -f "$TMP_NS_CONFIG"
            else
                echo "Error: could not apply skip_hosts to $NAMESPACE/$NS_AB_CM" >&2
                rm -f "$TMP_NS_CONFIG"
                exit 1
            fi
        fi
    fi
    echo ""
fi

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
  "createHttpRoute": true,
  "authBridgeEnabled": $AUTHBRIDGE_ENABLED,
  "spireEnabled": false
}
EOF
)

echo "Agent configuration:"
echo "$AGENT_JSON" | jq '.'
echo ""

HTTP_CODE=$(curl -s --max-time 30 -w "%{http_code}" -o /tmp/rossoctl_agent_response.txt -X POST "$ROSSOCTL_API/api/v1/agents" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$AGENT_JSON") || true

RESPONSE=$(cat /tmp/rossoctl_agent_response.txt)

echo "API Response (HTTP $HTTP_CODE):"
echo "$RESPONSE"
echo ""

if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "Error: Could not connect to Rossoctl API at $ROSSOCTL_API"
    echo "Please ensure Rossoctl backend is accessible via HTTP route"
    exit 1
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "✓ Agent deployment successful"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "Error: Rossoctl API returned 409 — agent still exists after deletion" >&2
    echo "  Response: $RESPONSE" >&2
    exit 1
else
    echo "Error: Rossoctl API deployment failed with HTTP $HTTP_CODE"
    exit 1
fi

echo ""

# Step 9: Conditionally patch imagePullPolicy
if [ "$USE_LOCAL_IMAGE" = "true" ]; then
    echo "Step 9: Patching imagePullPolicy to IfNotPresent..."
    sleep 2  # Give the deployment a moment to be created
    kubectl patch deployment $AGENT_NAME -n $NAMESPACE -p '{"spec":{"template":{"spec":{"containers":[{"name":"agent","imagePullPolicy":"IfNotPresent"}]}}}}' 2>/dev/null || echo "Warning: Could not patch imagePullPolicy"
    echo "✓ ImagePullPolicy patched"
else
    echo "Step 9: Patching imagePullPolicy... (skipped, K8s will pull from remote registry)"
fi
echo ""

# Step 9.5: Fix route targetPort on OpenShift.
# Rossoctl creates the route with targetPort: 8080 (the service port number), but
# OpenShift resolves targetPort by name when the service port has a name. The
# service port is named "http", so "8080" doesn't resolve and the router returns
# 503. Patch it to the port name so the route works.
if [ "$CLUSTER_MODE" = "openshift" ]; then
    kubectl patch route "$AGENT_NAME" -n "$NAMESPACE" \
        --type=json \
        -p='[{"op":"replace","path":"/spec/port/targetPort","value":"http"}]' \
        2>/dev/null && echo "✓ Route targetPort patched to 'http'" \
        || echo "Warning: Could not patch route targetPort (route may not exist yet)"
fi

# Step 10: Update openai-secret
echo "=========================================="
echo "Final Configuration"
echo "=========================================="
echo ""

# Step 10.1: Update secrets
if [ "$CLUSTER_MODE" = "kind" ]; then
    echo "Step 10.1: Updating secrets..."
    "$SCRIPT_DIR/update-secrets.sh" --namespace "$NAMESPACE"
else
    echo "Step 10.1: Updating secrets... (skipped — secrets are pre-provisioned on OpenShift/in-cluster)"
fi

echo ""

# Step 10.2/10.3: Set resource limits and wait for rollout (local/dev only).
if [ "$CLUSTER_MODE" = "in-cluster" ]; then
    echo "Step 10.2: Setting resource limits... (skipped — kubectl not available in-cluster)"
else
    echo "Step 10.2: Setting resource limits..."
    kubectl set resources deployment/$AGENT_NAME -n $NAMESPACE \
        --limits=cpu=4,memory=2Gi \
        --requests=cpu=500m,memory=512Mi 2>/dev/null \
        && echo "✓ Agent resource limits set (CPU: 4 cores, Memory: 2Gi)" \
        || echo "Warning: Could not set resource limits"
    echo ""

    echo "Step 10.3: Waiting for deployment to stabilize..."
    kubectl rollout status deployment/$AGENT_NAME -n $NAMESPACE --timeout=120s
    echo "✓ Deployment stable"
fi
echo ""

# Step 11: Wait for agent to be ready after the rollout triggered by set resources.
# Uses an HTTP health check (agent card endpoint) — kubectl is not available
# inside the job container.
echo "Step 11: Waiting for agent to be ready..."

AGENT_URL="$(agent_http_url "$AGENT_NAME" "$NAMESPACE")"
echo "  Agent URL: $AGENT_URL"

AGENT_READY=false
AGENT_MAX_WAIT=180
for i in $(seq 1 $AGENT_MAX_WAIT); do
    AGENT_HTTP_CODE=$(curl -s -o /tmp/agent_ready_response.txt -w "%{http_code}" --max-time 3 \
        "${AGENT_URL}/.well-known/agent-card.json" \
        2>/dev/null) || AGENT_HTTP_CODE="000"
    AGENT_RESPONSE=$(cat /tmp/agent_ready_response.txt 2>/dev/null || echo "")

    if [ "$AGENT_HTTP_CODE" = "200" ] && echo "$AGENT_RESPONSE" | jq empty 2>/dev/null; then
        echo "✓ Agent is ready (HTTP 200, valid JSON agent card)"
        AGENT_READY=true
        break
    fi

    if [ $((i % 15)) -eq 0 ]; then
        if echo "$AGENT_RESPONSE" | grep -q "upstream connect error\|reset before headers\|no healthy upstream"; then
            echo "  Gateway error — pod not ready yet... (${i}s)"
        else
            echo "  Waiting for agent... HTTP $AGENT_HTTP_CODE (${i}s)"
        fi
    fi
    sleep 1
done

if [ "$AGENT_READY" = false ]; then
    echo "Error: Agent did not become ready within ${AGENT_MAX_WAIT}s" >&2
    echo "  Last HTTP code: $AGENT_HTTP_CODE" >&2
    echo "  Last response:  $AGENT_RESPONSE" >&2
    exit 1
fi

echo ""

# Step 11.4: Apply the AuthBridge plugin pipeline overlay (if any
# plugin selector was supplied). The operator base config enables every
# supported plugin; this overlay sets on_error: off on the ones we
# didn't select and tunes config on the ones we did.
if [ "$AUTHBRIDGE_ENABLED" = "true" ]; then
    echo "Step 11.4: Applying AuthBridge pipeline overlay..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ ! -x "$SCRIPT_DIR/authbridge/apply-pipeline.sh" ]; then
        echo "Error: $SCRIPT_DIR/authbridge/apply-pipeline.sh not found or not executable"
        exit 1
    fi
    AGENT_NAME="$AGENT_NAME" NAMESPACE="$NAMESPACE" \
        PIPELINE_PLUGINS="$PIPELINE_PLUGINS" \
        PIPELINE_OVERLAY_FILE="${PIPELINE_OVERLAY_FILE:-}" \
        OPENAI_API_BASE="${OPENAI_API_BASE:-}" \
        IBAC_JUDGE_ENDPOINT="${IBAC_JUDGE_ENDPOINT:-}" \
        IBAC_JUDGE_MODEL="${IBAC_JUDGE_MODEL:-}" \
        IBAC_AGENT_LLM_HOST="${IBAC_AGENT_LLM_HOST:-}" \
        IBAC_TIMEOUT_MS="${IBAC_TIMEOUT_MS:-}" \
        JUDGE_BEARER="${JUDGE_BEARER:-}" \
        OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        TOKEN_BROKER_URL="${TOKEN_BROKER_URL:-}" \
        TOKEN_BROKER_AUDIENCE="${TOKEN_BROKER_AUDIENCE:-}" \
        "$SCRIPT_DIR/authbridge/apply-pipeline.sh"
    echo ""
fi

# Step 12: Agent card already verified in Step 11; just show it.
echo "Step 12: Agent card:"
AGENT_HTTP_ROUTE_URL="$(agent_http_url "$AGENT_NAME" "$NAMESPACE")"
CARD_RESPONSE=$(curl -s --max-time 5 "${AGENT_HTTP_ROUTE_URL}/.well-known/agent-card.json" 2>/dev/null || echo "")
echo "$CARD_RESPONSE" | jq '.name, .description' 2>/dev/null || echo "  (could not re-fetch card)"

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
if [ "$AUTHBRIDGE_ENABLED" = "true" ]; then
    echo "  Plugins (resolved): ${PIPELINE_PLUGINS:-<none enforced>}"
    [ -n "$PIPELINE_OVERLAY_FILE" ] && echo "  Plugin overlay file: $PIPELINE_OVERLAY_FILE"
else
    echo "  AuthBridge sidecar: disabled (no plugin selectors supplied)"
fi
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
