#!/bin/bash
# Delete all agent and benchmark (tool) deployments from a Rossoctl namespace via the API.
# Usage: ./delete-all-deployments.sh [OPTIONS]
# Example: ./delete-all-deployments.sh --openshift apps.mycluster.example.com
# Example: ./delete-all-deployments.sh --kind
# Example: ./delete-all-deployments.sh --dry-run

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line#export }"
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        if [ -z "${!key+x}" ]; then
            export "$key=$val"
        fi
    done <"$ENV_FILE"
fi

KEYCLOAK_USERNAME="admin"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-unknown}"
NAMESPACE="team1"
CLUSTER_MODE=""
INGRESS_DOMAIN=""
DRY_RUN="false"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Delete all agent and benchmark deployments in a Rossoctl namespace via the API.

Cluster selection (exactly one required):
  --kind                      Target local Kind cluster (default for local dev)
  --openshift <domain>        Target OpenShift cluster with given ingress domain
  --in-cluster                Run as a Kubernetes Job pod (uses in-cluster DNS)

Options:
  --namespace <ns>            Rossoctl namespace (default: team1)
  --keycloak-user <user>      Keycloak username (default: admin)
  --keycloak-pass <pass>      Keycloak password (overrides KEYCLOAK_PASSWORD env)
  --dry-run                   List what would be deleted without deleting anything
  -h, --help                  Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
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
        --namespace)
            NAMESPACE="$2"
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
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument: $1"
            usage
            ;;
    esac
done

export CLUSTER_MODE INGRESS_DOMAIN
# shellcheck source=libsh/urls.sh
source "$SCRIPT_DIR/libsh/urls.sh"
# shellcheck source=libsh/check-kubectl-context.sh
source "$SCRIPT_DIR/libsh/check-kubectl-context.sh"
check_kubectl_context

ROSSOCTL_API="$(rossoctl_api_url)"
KEYCLOAK_API="$(keycloak_api_url)"

echo "=========================================="
echo " Delete All Deployments"
echo "=========================================="
echo "  Namespace:   $NAMESPACE"
echo "  Rossoctl API: $ROSSOCTL_API"
echo "  Dry run:     $DRY_RUN"
echo "=========================================="
echo ""

# Step 1: Get Keycloak authentication token
echo "Step 1: Getting Keycloak authentication token..."

if [ "$KEYCLOAK_PASSWORD" = "unknown" ]; then
    echo "Step 1.5: Attempting to fetch Keycloak password from cluster..."
    ROSSOCTL_PASSWORD=$("$KUBECTL_BIN" get secret rossoctl-test-user -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$ROSSOCTL_PASSWORD" ]; then
        TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=$KEYCLOAK_USERNAME" \
            -d "password=$ROSSOCTL_PASSWORD" \
            -d "grant_type=password" \
            -d "client_id=rossoctl" 2>/dev/null || echo "")
        if echo "$TEST_AUTH" | grep -q "access_token"; then
            KEYCLOAK_PASSWORD="$ROSSOCTL_PASSWORD"
            echo "✓ Fetched Keycloak password from cluster"
        else
            echo "⚠ Warning: Fetched password from cluster but authentication failed"
            exit 1
        fi
    else
        TEST_AUTH=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=$KEYCLOAK_USERNAME" \
            -d "password=admin" \
            -d "grant_type=password" \
            -d "client_id=rossoctl" 2>/dev/null || echo "")
        if echo "$TEST_AUTH" | grep -q "access_token"; then
            KEYCLOAK_PASSWORD="admin"
            echo "✓ Using default Keycloak password"
        else
            echo "Error: Could not determine Keycloak password. Use --keycloak-pass."
            exit 1
        fi
    fi
fi

TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_API/realms/rossoctl/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$KEYCLOAK_USERNAME" \
    -d "password=$KEYCLOAK_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=rossoctl" || echo "TOKEN_ERROR")

if [ "$TOKEN_RESPONSE" = "TOKEN_ERROR" ]; then
    echo "Error: Failed to reach Keycloak at $KEYCLOAK_API"
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')
if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to extract access token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi
echo "✓ Authentication token obtained"
echo ""

# Step 2: Verify Rossoctl backend is accessible
echo "Step 2: Verifying Rossoctl backend accessibility at $ROSSOCTL_API..."
if ! curl -s --max-time 10 "$ROSSOCTL_API/api/v1/namespaces" >/dev/null 2>&1; then
    echo "Error: Rossoctl backend is not accessible at $ROSSOCTL_API"
    exit 1
fi
echo "✓ Rossoctl backend is accessible"
echo ""

# Step 3: Discover deployments via kubectl
# Agents are named exgentic-a2a-*, tools/benchmarks are named exgentic-mcp-*
echo "Step 3: Listing deployments in namespace '$NAMESPACE'..."
ALL_DEPLOYMENTS=$("$KUBECTL_BIN" get deployments -n "$NAMESPACE" \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

AGENT_NAMES=$(echo "$ALL_DEPLOYMENTS" | grep "^exgentic-a2a-" || true)
TOOL_NAMES=$(echo "$ALL_DEPLOYMENTS" | grep "^exgentic-mcp-" || true)

if [ -z "$AGENT_NAMES" ]; then
    echo "  No agents found."
else
    echo "  Found agents:"
    echo "$AGENT_NAMES" | while read -r name; do
        echo "    - $name"
    done
fi
echo ""

echo "Step 4: Listing tools (benchmarks) in namespace '$NAMESPACE'..."
if [ -z "$TOOL_NAMES" ]; then
    echo "  No tools found."
else
    echo "  Found tools:"
    echo "$TOOL_NAMES" | while read -r name; do
        echo "    - $name"
    done
fi
echo ""

if [ "$DRY_RUN" = "true" ]; then
    echo "Dry-run mode — no deletions performed."
    exit 0
fi

# wait_for_gone <type> <name> <api_path> — polls until the record is 404 or 30s elapses.
wait_for_gone() {
    local resource_type="$1" name="$2" api_path="$3"
    local elapsed=0 max=30 code
    while true; do
        code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
            "$ROSSOCTL_API$api_path" \
            -H "Authorization: Bearer $ACCESS_TOKEN") || code="000"
        [ "$code" = "404" ] && echo "    ✓ $resource_type '$name' confirmed gone" && return 0
        if [ "$elapsed" -ge "$max" ]; then
            echo "    ⚠ $resource_type '$name' still present after ${max}s — Rossoctl cleanup stalled"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# Step 5: Delete all agents
if [ -n "$AGENT_NAMES" ]; then
    echo "Step 5: Deleting agents..."
    echo "$AGENT_NAMES" | while read -r name; do
        [ -z "$name" ] && continue
        echo -n "  Deleting agent '$name'... "
        HTTP=$(curl -s --max-time 30 -w "%{http_code}" -o /tmp/rossoctl_del_agent.txt \
            -X DELETE "$ROSSOCTL_API/api/v1/agents/$NAMESPACE/$name" \
            -H "Authorization: Bearer $ACCESS_TOKEN") || HTTP="000"
        if [ "$HTTP" = "200" ] || [ "$HTTP" = "404" ]; then
            echo "done (HTTP $HTTP)"
            [ "$HTTP" = "200" ] && wait_for_gone "agent" "$name" "/api/v1/agents/$NAMESPACE/$name"
        else
            echo "FAILED (HTTP $HTTP)"
            cat /tmp/rossoctl_del_agent.txt
        fi
    done
else
    echo "Step 5: No agents to delete."
fi
echo ""

# Step 6: Delete all tools
if [ -n "$TOOL_NAMES" ]; then
    echo "Step 6: Deleting tools (benchmarks)..."
    echo "$TOOL_NAMES" | while read -r name; do
        [ -z "$name" ] && continue
        echo -n "  Deleting tool '$name'... "
        HTTP=$(curl -s --max-time 30 -w "%{http_code}" -o /tmp/rossoctl_del_tool.txt \
            -X DELETE "$ROSSOCTL_API/api/v1/tools/$NAMESPACE/$name" \
            -H "Authorization: Bearer $ACCESS_TOKEN") || HTTP="000"
        if [ "$HTTP" = "200" ] || [ "$HTTP" = "404" ]; then
            echo "done (HTTP $HTTP)"
            [ "$HTTP" = "200" ] && wait_for_gone "tool" "$name" "/api/v1/tools/$NAMESPACE/$name"
        else
            echo "FAILED (HTTP $HTTP)"
            cat /tmp/rossoctl_del_tool.txt
        fi
    done
else
    echo "Step 6: No tools to delete."
fi
echo ""

echo "=========================================="
echo " Done"
echo "=========================================="
