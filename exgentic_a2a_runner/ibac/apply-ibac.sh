#!/bin/bash
# Apply the IBAC plugin to a deployed agent's authbridge sidecar.
# Called by deploy-agent.sh when --ibac is set.
#
# This patches the operator-rendered `authbridge-config-<agent>` ConfigMap
# to add the IBAC plugin (plus its inbound/outbound parser dependencies)
# to the existing authbridge-proxy sidecar's pipeline. Authbridge's
# filesystem-watch hot-reload picks up the change without a pod restart.
#
# Pipeline shape after this script runs:
#   inbound:  a2a-parser, jwt-validation
#   outbound: token-exchange, inference-parser, mcp-parser, ibac
#
# Inputs (from env):
#   AGENT_NAME            Required. Target Deployment name.
#   NAMESPACE             Required. Target namespace.
#   IBAC_JUDGE_ENDPOINT   Judge LLM base URL (default: http://host.docker.internal:11434).
#   IBAC_JUDGE_MODEL      Judge model id (default: llama3.2:3b).
#   IBAC_AGENT_LLM_HOST   Hostname of the agent's own LLM endpoint, added to bypass list
#                         so reasoning calls aren't judged. Auto-derived from
#                         OPENAI_API_BASE when set; otherwise host.docker.internal.
#   IBAC_TIMEOUT_MS       Per-judge-call timeout in ms (default: 15000).
#
# Prerequisite: the cluster's authbridge-proxy image must include the
# `ibac` plugin. If it doesn't, the merge will validate but the sidecar
# will fail at Configure with `unknown plugin "ibac"` after the reload.

set -euo pipefail

: "${AGENT_NAME:?AGENT_NAME is required}"
: "${NAMESPACE:?NAMESPACE is required}"

IBAC_DIR="$(cd "$(dirname "$0")" && pwd)"

IBAC_JUDGE_ENDPOINT="${IBAC_JUDGE_ENDPOINT:-http://host.docker.internal:11434}"
IBAC_JUDGE_MODEL="${IBAC_JUDGE_MODEL:-llama3.2:3b}"
IBAC_TIMEOUT_MS="${IBAC_TIMEOUT_MS:-15000}"

# Auto-derive the agent's LLM host from OPENAI_API_BASE if the caller
# didn't set IBAC_AGENT_LLM_HOST explicitly. Falls back to
# host.docker.internal (the default ollama path) when neither is set.
if [ -z "${IBAC_AGENT_LLM_HOST:-}" ]; then
    if [ -n "${OPENAI_API_BASE:-}" ]; then
        IBAC_AGENT_LLM_HOST=$(echo "$OPENAI_API_BASE" | sed -E 's#^https?://##; s#[:/].*$##')
    else
        IBAC_AGENT_LLM_HOST="host.docker.internal"
    fi
fi
export IBAC_JUDGE_ENDPOINT IBAC_JUDGE_MODEL IBAC_AGENT_LLM_HOST IBAC_TIMEOUT_MS

CM_NAME="authbridge-config-$AGENT_NAME"
PATCH_TMPL="$IBAC_DIR/ibac-patch.yaml"
PROMPT_FILE="$IBAC_DIR/intent_prompt.txt"
MERGE_PY="$IBAC_DIR/ibac-merge.py"
WAIT_RELOAD="$IBAC_DIR/wait-for-reload.sh"

echo "Applying IBAC plugin to $NAMESPACE/$AGENT_NAME"
echo "  Judge endpoint:        $IBAC_JUDGE_ENDPOINT"
echo "  Judge model:           $IBAC_JUDGE_MODEL"
echo "  Agent LLM host bypass: $IBAC_AGENT_LLM_HOST"
echo "  Per-call timeout:      ${IBAC_TIMEOUT_MS}ms"

# Pre-flight: PyYAML (the merge script needs it).
if ! python3 -c 'import yaml' 2>/dev/null; then
    cat <<'EOF' >&2
ERROR: python3 with PyYAML is required.
  Install with one of:
    pip3 install --user pyyaml
    brew install libyaml && pip3 install pyyaml      # macOS
    sudo apt install python3-yaml                    # Debian/Ubuntu
EOF
    exit 1
fi

# Pre-flight: envsubst.
if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not found. Install gettext (apt install gettext-base | brew install gettext)." >&2
    exit 1
fi

# Pre-flight: the operator should have created the agent's authbridge ConfigMap.
if ! kubectl -n "$NAMESPACE" get configmap "$CM_NAME" >/dev/null 2>&1; then
    echo "ERROR: ConfigMap $NAMESPACE/$CM_NAME not found." >&2
    echo "       The kagenti operator should create this when the agent pod is admitted." >&2
    echo "       Check: kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=$AGENT_NAME" >&2
    exit 1
fi

# Pre-flight: confirm intent_prompt.txt exists and is non-empty. We
# always inject it as system_prompt; if it's missing the deployment
# would silently fall back to the plugin's default prompt and exgentic
# verdicts would shift.
if [ ! -s "$PROMPT_FILE" ]; then
    echo "ERROR: $PROMPT_FILE is missing or empty." >&2
    echo "       The IBAC judge's system prompt is shipped via this file." >&2
    exit 1
fi

# Render the patch template: substitute ${IBAC_*} env vars.
RENDERED_PATCH=$(mktemp -t ibac-patch.XXXXXX.yaml)
trap 'rm -f "$RENDERED_PATCH"' EXIT
envsubst <"$PATCH_TMPL" >"$RENDERED_PATCH"

# Merge the additions into the operator's config and inject the
# system_prompt from intent_prompt.txt.
echo "[*] Merging IBAC additions into $CM_NAME ..."
MERGED_YAML=$(
    kubectl -n "$NAMESPACE" get configmap "$CM_NAME" \
        -o jsonpath='{.data.config\.yaml}' \
        | python3 "$MERGE_PY" "$RENDERED_PATCH" --prompt-file "$PROMPT_FILE"
)

if [ -z "$MERGED_YAML" ]; then
    echo "ERROR: merge produced empty output" >&2
    exit 1
fi

# Apply via the conflict-free `create --dry-run | apply` pattern
# (sidesteps resource-version mismatches you'd hit if you piped the
# existing CM through edits and re-applied directly).
echo "[*] Applying patched ConfigMap ..."
TMP_CONFIG=$(mktemp)
trap 'rm -f "$RENDERED_PATCH" "$TMP_CONFIG"' EXIT
printf '%s' "$MERGED_YAML" >"$TMP_CONFIG"
kubectl -n "$NAMESPACE" create configmap "$CM_NAME" \
    --from-file=config.yaml="$TMP_CONFIG" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

echo "[*] Active plugins after patch:"
kubectl -n "$NAMESPACE" get configmap "$CM_NAME" \
    -o jsonpath='{.data.config\.yaml}' \
    | python3 -c '
import yaml, sys
c = yaml.safe_load(sys.stdin)
for d in ("inbound", "outbound"):
    names = [p["name"] for p in c.get("pipeline", {}).get(d, {}).get("plugins", [])]
    print(f"      {d}: {names}")
'

# Wait for the sidecar's hot-reload to pick up the new config.
bash "$WAIT_RELOAD" "$NAMESPACE" "$AGENT_NAME" 120

echo "✓ IBAC plugin applied"
