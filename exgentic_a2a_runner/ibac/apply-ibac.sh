#!/bin/bash
# Apply the IBAC overlay (Envoy ConfigMap + deployment patch) to a deployed agent.
# Called by deploy-agent.sh when --ibac is set.
#
# Inputs (from env):
#   AGENT_NAME                       Required. Target Deployment name.
#   NAMESPACE                        Required. Target namespace.
#   TOOL_NAME                        Required. MCP service name prefix (used for default trusted destinations).
#   IBAC_SIDECAR_IMAGE               Sidecar image (default: localhost/ibac-sidecar:latest)
#   IBAC_ENVOY_IMAGE                 Envoy image (default: envoyproxy/envoy:v1.28-latest)
#   IBAC_OLLAMA_URL                  Validator LLM endpoint (default: http://host.docker.internal:11434)
#   IBAC_TRUSTED_DESTINATIONS        Comma-separated host[:port] list that bypasses validation.
#                                    If unset, a sensible default covering Kagenti infra is used.
#   OPENAI_API_BASE                  Optional. If set, its host is auto-added to trusted destinations.

set -e

: "${AGENT_NAME:?AGENT_NAME is required}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${TOOL_NAME:?TOOL_NAME is required}"

IBAC_DIR="$(cd "$(dirname "$0")" && pwd)"

IBAC_SIDECAR_IMAGE="${IBAC_SIDECAR_IMAGE:-localhost/ibac-sidecar:latest}"
IBAC_ENVOY_IMAGE="${IBAC_ENVOY_IMAGE:-envoyproxy/envoy:v1.28-latest}"
IBAC_OLLAMA_URL="${IBAC_OLLAMA_URL:-http://host.docker.internal:11434}"

# Build the default trusted-destinations list. Only Kagenti infra (keycloak,
# OTEL collector) and the Ollama validator host are trusted by default. The
# benchmark MCP service is NOT trusted — the sidecar LLM-validates every
# tools/call against the captured user intent. MCP framing calls (initialize,
# tools/list, notifications) are auto-allowed by the sidecar without needing
# a session.
#
# LLM calls to OPENAI_API_BASE aren't listed because they flow via the TLS
# passthrough listener (port 443 -> :10003) and never reach the sidecar.
#
# Override by exporting IBAC_TRUSTED_DESTINATIONS before running. To re-trust
# MCP (skip per-call validation, e.g. for fast benchmark runs without a
# validator LLM running):
#   IBAC_TRUSTED_DESTINATIONS="${TOOL_NAME}-mcp:8000,..."
DEFAULT_TRUSTED="keycloak.keycloak.svc.cluster.local:8080"
DEFAULT_TRUSTED+=",otel-collector.kagenti-system.svc.cluster.local:8335"
# Always include the Ollama host so the sidecar's own LLM calls aren't recursively validated.
OLLAMA_HOST=$(echo "$IBAC_OLLAMA_URL" | sed -E 's#^https?://##; s#/.*$##')
if [ -n "$OLLAMA_HOST" ]; then
    DEFAULT_TRUSTED+=",${OLLAMA_HOST}"
fi

IBAC_TRUSTED_DESTINATIONS="${IBAC_TRUSTED_DESTINATIONS:-$DEFAULT_TRUSTED}"

echo "Applying IBAC overlay to $NAMESPACE/$AGENT_NAME"
echo "  Sidecar image:         $IBAC_SIDECAR_IMAGE"
echo "  Envoy image:           $IBAC_ENVOY_IMAGE"
echo "  Ollama URL:            $IBAC_OLLAMA_URL"
echo "  Trusted destinations:  $IBAC_TRUSTED_DESTINATIONS"

# Apply the Envoy ConfigMap into the target namespace (it's namespace-hardcoded
# in the file; override by stripping and re-emitting the namespace).
ENVOY_CFG="$IBAC_DIR/envoy-config.yaml"
if [ ! -f "$ENVOY_CFG" ]; then
    echo "Error: $ENVOY_CFG not found"
    exit 1
fi

# Use kubectl -n to force namespace regardless of what's in the file.
sed -E "s#(^  namespace:).*#\1 ${NAMESPACE}#" "$ENVOY_CFG" | kubectl apply -f -

# Optional: if intent_prompt.txt is present locally, mount it into the sidecar
# via a ConfigMap. Otherwise the sidecar uses its baked-in default.
INTENT_PROMPT_FILE="$IBAC_DIR/intent_prompt.txt"
if [ -f "$INTENT_PROMPT_FILE" ]; then
    echo "  Intent prompt:         $INTENT_PROMPT_FILE (mounted via ConfigMap)"
    kubectl -n "$NAMESPACE" create configmap ibac-intent-prompt \
        --from-file=intent_prompt.txt="$INTENT_PROMPT_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "  Intent prompt:         (using baked-in default; no $INTENT_PROMPT_FILE)"
    # Best-effort cleanup so a stale ConfigMap from a previous run doesn't override the default.
    kubectl -n "$NAMESPACE" delete configmap ibac-intent-prompt --ignore-not-found >/dev/null 2>&1 || true
fi

# Render the deployment patch with env-specific values, then apply.
PATCH_TMPL="$IBAC_DIR/patch-deployment.yaml"
if [ ! -f "$PATCH_TMPL" ]; then
    echo "Error: $PATCH_TMPL not found"
    exit 1
fi

RENDERED_PATCH=$(mktemp -t ibac-patch.XXXXXX.yaml)
trap "rm -f $RENDERED_PATCH" EXIT

# Substitute image refs and the trusted destinations list. Use `|` as sed
# delimiter since values contain `/` and `.`.
sed \
    -e "s|localhost/ibac-sidecar:latest|${IBAC_SIDECAR_IMAGE}|" \
    -e "s|envoyproxy/envoy:v1.28-latest|${IBAC_ENVOY_IMAGE}|" \
    -e "s|http://host.docker.internal:11434|${IBAC_OLLAMA_URL}|" \
    "$PATCH_TMPL" > "$RENDERED_PATCH"

# Replace the TRUSTED_DESTINATIONS value line (it's multi-word so do it with awk
# to avoid escaping the user-provided list).
awk -v tl="$IBAC_TRUSTED_DESTINATIONS" '
    /TRUSTED_DESTINATIONS/ { print; in_trusted=1; next }
    in_trusted && /value:/ { sub(/value: .*/, "value: \"" tl "\""); in_trusted=0 }
    { print }
' "$RENDERED_PATCH" > "${RENDERED_PATCH}.new" && mv "${RENDERED_PATCH}.new" "$RENDERED_PATCH"

kubectl -n "$NAMESPACE" patch deployment "$AGENT_NAME" --patch-file "$RENDERED_PATCH"

echo "Waiting for IBAC-enabled rollout..."
kubectl -n "$NAMESPACE" rollout status "deployment/$AGENT_NAME" --timeout=180s

echo "✓ IBAC overlay applied"
