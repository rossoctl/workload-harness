#!/bin/bash
# Apply a resolved AuthBridge plugin pipeline to a deployed agent's
# authbridge sidecar. Called by deploy-agent.sh after the operator has
# rendered `authbridge-config-<agent>`.
#
# This patches the operator-rendered ConfigMap to install the resolved
# plugin selection (with per-plugin on_error policies). Authbridge's
# filesystem-watch hot-reload picks up the change without a pod
# restart; if a fresh pod boots first, the patched ConfigMap is mounted
# from the start. wait-for-reload.sh handles both convergence paths.
#
# Inputs (from env):
#   AGENT_NAME              Required. Target Deployment name.
#   NAMESPACE               Required. Target namespace.
#   PIPELINE_PLUGINS        Required. Space-separated `name[:policy]`
#                           tokens (the resolved selection from the
#                           deploy-agent.sh resolver).
#   PIPELINE_OVERLAY_FILE   Optional. Path to a flat-map per-plugin
#                           config-override file (--plugin-config-file).
#   IBAC_*, TOKEN_BROKER_*  Consumed by the corresponding plugin
#                           fragments via envsubst (see plugins/*.yaml).
#
# Prerequisite: the cluster's authbridge sidecar image must include
# every plugin in the resolved selection. The merge will validate the
# YAML shape but the sidecar will fail at Configure with `unknown
# plugin "<name>"` after reload if a plugin isn't compiled in.

set -euo pipefail

: "${AGENT_NAME:?AGENT_NAME is required}"
: "${NAMESPACE:?NAMESPACE is required}"
: "${PIPELINE_PLUGINS:?PIPELINE_PLUGINS is required (space-separated name[:policy] tokens)}"

AB_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGINS_DIR="$AB_DIR/plugins"
MERGE_PY="$AB_DIR/pipeline-merge.py"
PROMPT_FILE="$AB_DIR/intent_prompt.txt"
WAIT_RELOAD="$AB_DIR/wait-for-reload.sh"

CM_NAME="authbridge-config-$AGENT_NAME"

# --- IBAC defaults (only consumed when ibac is in the resolved set, but
# we always export so envsubst can render the fragment). Mirrors the
# defaults the legacy apply-ibac.sh shipped.
IBAC_JUDGE_ENDPOINT="${IBAC_JUDGE_ENDPOINT:-http://host.docker.internal:11434}"
IBAC_JUDGE_MODEL="${IBAC_JUDGE_MODEL:-llama3.2:3b}"
IBAC_TIMEOUT_MS="${IBAC_TIMEOUT_MS:-15000}"
if [ -z "${IBAC_AGENT_LLM_HOST:-}" ]; then
    if [ -n "${OPENAI_API_BASE:-}" ]; then
        IBAC_AGENT_LLM_HOST=$(echo "$OPENAI_API_BASE" | sed -E 's#^https?://##; s#[:/].*$##')
    else
        IBAC_AGENT_LLM_HOST="host.docker.internal"
    fi
fi
JUDGE_BEARER="${JUDGE_BEARER:-${OPENAI_API_KEY:-}}"
export IBAC_JUDGE_ENDPOINT IBAC_JUDGE_MODEL IBAC_AGENT_LLM_HOST IBAC_TIMEOUT_MS JUDGE_BEARER

# --- token-broker defaults (consumed only when token-broker is selected).
TOKEN_BROKER_URL="${TOKEN_BROKER_URL:-}"
TOKEN_BROKER_AUDIENCE="${TOKEN_BROKER_AUDIENCE:-}"
export TOKEN_BROKER_URL TOKEN_BROKER_AUDIENCE

echo "Applying AuthBridge pipeline to $NAMESPACE/$AGENT_NAME"
echo "  Plugins: $PIPELINE_PLUGINS"
if [ -n "${PIPELINE_OVERLAY_FILE:-}" ]; then
    echo "  Overlay: $PIPELINE_OVERLAY_FILE"
fi

# --- Pre-flight: PyYAML.
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

# --- Pre-flight: envsubst.
if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not found. Install gettext (apt install gettext-base | brew install gettext)." >&2
    exit 1
fi

# --- Pre-flight: ConfigMap exists.
if ! kubectl -n "$NAMESPACE" get configmap "$CM_NAME" >/dev/null 2>&1; then
    echo "ERROR: ConfigMap $NAMESPACE/$CM_NAME not found." >&2
    echo "       The rossoctl operator should create this when the agent pod is admitted." >&2
    echo "       Check: kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=$AGENT_NAME" >&2
    exit 1
fi

# --- Pre-flight: validate plugin names in PIPELINE_PLUGINS up front so
# we fail before any kubectl call.
KNOWN_PLUGINS=(jwt-validation token-exchange token-broker a2a-parser mcp-parser inference-parser ibac)
VALID_POLICIES=(enforce observe off)
is_known() { local needle=$1; shift; for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done; return 1; }
for tok in $PIPELINE_PLUGINS; do
    name=${tok%%:*}
    policy=${tok#*:}
    [[ "$policy" == "$tok" ]] && policy=enforce
    if ! is_known "$name" "${KNOWN_PLUGINS[@]}"; then
        echo "ERROR: unknown plugin '$name' in PIPELINE_PLUGINS. Known: ${KNOWN_PLUGINS[*]}" >&2
        exit 1
    fi
    if ! is_known "$policy" "${VALID_POLICIES[@]}"; then
        echo "ERROR: unknown policy '$policy' for plugin '$name'. Valid: ${VALID_POLICIES[*]}" >&2
        exit 1
    fi
done

# --- Pre-flight: confirm intent_prompt.txt exists when ibac is active.
# Mirrors the legacy guard: if the prompt is missing the deployment
# silently falls back to the plugin's default and exgentic verdicts shift.
ibac_active=false
for tok in $PIPELINE_PLUGINS; do
    name=${tok%%:*}
    policy=${tok#*:}; [[ "$policy" == "$tok" ]] && policy=enforce
    if [[ "$name" == "ibac" && "$policy" != "off" ]]; then
        ibac_active=true
        break
    fi
done
if $ibac_active && [ ! -s "$PROMPT_FILE" ]; then
    echo "ERROR: $PROMPT_FILE is missing or empty." >&2
    echo "       The IBAC judge's system prompt is shipped via this file." >&2
    exit 1
fi

# --- Render every plugin fragment with envsubst into a temp dir. The
# merge script reads these as the rendered defaults; --plugin-config-file
# overrides are deep-merged on top inside pipeline-merge.py.
RENDERED_DIR=$(mktemp -d -t authbridge-pipeline.XXXXXX)
trap 'rm -rf "$RENDERED_DIR"' EXIT
for name in "${KNOWN_PLUGINS[@]}"; do
    src="$PLUGINS_DIR/$name.yaml"
    if [ ! -f "$src" ]; then
        echo "ERROR: plugin fragment missing: $src" >&2
        exit 1
    fi
    envsubst <"$src" >"$RENDERED_DIR/$name.yaml"
done

# --- Pull the operator's current ConfigMap content and run the merge.
echo "[*] Merging pipeline into $CM_NAME ..."
CURRENT_YAML=$(
    kubectl -n "$NAMESPACE" get configmap "$CM_NAME" \
        -o jsonpath='{.data.config\.yaml}'
)

merge_args=(
    --plugins-dir "$RENDERED_DIR"
    --plugins "$PIPELINE_PLUGINS"
)
if $ibac_active; then
    merge_args+=(--prompt-file "$PROMPT_FILE")
fi
if [ -n "${PIPELINE_OVERLAY_FILE:-}" ]; then
    if [ ! -f "$PIPELINE_OVERLAY_FILE" ]; then
        echo "ERROR: --plugin-config-file not found: $PIPELINE_OVERLAY_FILE" >&2
        exit 1
    fi
    merge_args+=(--config-file "$PIPELINE_OVERLAY_FILE")
fi

MERGED_YAML=$(printf '%s' "$CURRENT_YAML" | python3 "$MERGE_PY" "${merge_args[@]}")

if [ -z "$MERGED_YAML" ]; then
    echo "ERROR: merge produced empty output" >&2
    exit 1
fi

# --- No-op short-circuit. If the merged YAML is byte-identical to what's
# already in the ConfigMap, skip the kubectl apply AND the reload-wait.
# Otherwise we'd block forever on a swap event that never fires (kubelet
# has nothing to sync; the reloader sees no fs event).
if [ "$CURRENT_YAML" = "$MERGED_YAML" ]; then
    echo "[*] $CM_NAME already matches resolved pipeline — nothing to patch."
    echo "[*] Active plugins:"
    printf '%s' "$CURRENT_YAML" | python3 -c '
import yaml, sys
c = yaml.safe_load(sys.stdin)
for d in ("inbound", "outbound"):
    entries = c.get("pipeline", {}).get(d, {}).get("plugins", [])
    rendered = []
    for p in entries:
        n = p.get("name")
        oe = p.get("on_error")
        rendered.append(f"{n}:{oe}" if oe else n)
    print(f"      {d}: {rendered}")
'
    echo "✓ Pipeline already applied"
    exit 0
fi

# --- Apply via the conflict-free `create --dry-run | apply` pattern
# (sidesteps resource-version mismatches you'd hit if you piped the
# existing CM through edits and re-applied directly).
echo "[*] Applying patched ConfigMap ..."
TMP_CONFIG=$(mktemp)
trap 'rm -rf "$RENDERED_DIR" "$TMP_CONFIG"' EXIT
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
    entries = c.get("pipeline", {}).get(d, {}).get("plugins", [])
    rendered = []
    for p in entries:
        n = p.get("name")
        oe = p.get("on_error")
        rendered.append(f"{n}:{oe}" if oe else n)
    print(f"      {d}: {rendered}")
'

# --- Wait for the sidecar to be running the patched config. SHA-256
# compare against active_config_sha256 from :9093/reload/status — works
# for both hot-reload and pod-roll convergence paths.
WANT_SHA=$(printf '%s' "$MERGED_YAML" | sha256sum | awk '{print $1}')
bash "$WAIT_RELOAD" "$NAMESPACE" "$AGENT_NAME" "$WANT_SHA" 180

echo "✓ Pipeline applied"
