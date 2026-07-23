#!/bin/bash
# Block until the authbridge sidecar is running a config whose
# SHA-256 matches what we just applied. Times out after $TIMEOUT
# seconds.
#
# Usage: wait-for-reload.sh <namespace> <agent-name> <want-sha> [timeout-seconds]
#
# The sidecar exposes its active config's SHA on :9093/reload/status
# (`active_config_sha256`). Comparing SHAs handles both convergence
# pathways uniformly:
#
#   - Hot-reload: same pod, the reloader detects the projected-volume
#     symlink swap (kubelet syncs every ~60s) and rebuilds pipelines;
#     active_config_sha256 advances on swap completion.
#   - Pod-roll: a fresh pod (e.g. operator's reconciler restarted the
#     deployment) boots with the patched ConfigMap mounted from the
#     start, so its initial active_config_sha256 already matches.
#
# Tailing logs for "reloader: pipelines swapped" only catches the
# hot-reload path and misses the pod-roll path entirely.
#
# The operator-injected sidecar container name varies by operator
# version. Known names, oldest → newest:
#   - `envoy-proxy`     legacy 3-container layout (Envoy + ext_proc)
#   - `authbridge`      post-#411 combined image
#   - `authbridge-proxy` post-binary-split (proxy-sidecar mode);
#                        the operator picks this name when injecting
#                        the proxy-sidecar binary
# This script auto-detects which one is in the pod. During a rollout it
# probes every sidecar-bearing pod each poll and succeeds as soon as any
# reports the target SHA, so it doesn't matter which pod is "first".

set -euo pipefail

NAMESPACE=${1:?namespace required}
AGENT_NAME=${2:?agent name required}
WANT_SHA=${3:?want-sha required}
TIMEOUT=${4:-180}

# The operator-injected sidecar container is one of these names,
# depending on operator version (see header comment).
AUTHBRIDGE_CANDIDATES=(authbridge-proxy authbridge envoy-proxy)

# Enumerate the agent's pods and, for each, the authbridge sidecar
# container it carries (if any). Emits one "pod<TAB>container" line per
# sidecar-bearing pod. We re-run this every poll iteration rather than
# picking a single pod up front:
#
#   During a rollout the pod list contains, in arbitrary order, the old
#   pod (agent-only if it predates AuthBridge, or a sidecar still serving
#   the stale config) alongside the new pod (mounting the patched
#   ConfigMap). The old `.items[0]` assumption picked whichever came first
#   — often the old/agent-only pod — and then either failed to find a
#   sidecar at all or waited forever on a pod whose config will never
#   advance (it's being terminated). Because success is defined purely by
#   "some sidecar reports the target SHA", we just probe every sidecar pod
#   each round; the converged pod wins regardless of list order, and
#   old/terminating pods that never match are harmless.
list_sidecar_pods() {
  kubectl -n "$NAMESPACE" get pods \
      -l app.kubernetes.io/name="$AGENT_NAME" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' \
      2>/dev/null | while IFS='|' read -r pod containers; do
    [[ -z "$pod" ]] && continue
    for candidate in "${AUTHBRIDGE_CANDIDATES[@]}"; do
      if echo "$containers" | tr ',' '\n' | grep -qx "$candidate"; then
        printf '%s\t%s\n' "$pod" "$candidate"
        break
      fi
    done
  done
}

DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "[*] Waiting for authbridge to load the patched config (timeout ${TIMEOUT}s)"
echo "    target SHA: $WANT_SHA"

SAW_SIDECAR=false     # did we ever find a sidecar-bearing pod?
LAST_POD=""           # for the failure diagnostics
LAST_CONTAINER=""
LAST_SHA=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  SIDECAR_PODS=$(list_sidecar_pods || true)
  if [[ -n "$SIDECAR_PODS" ]]; then
    SAW_SIDECAR=true
    while IFS=$'\t' read -r pod container; do
      [[ -z "$pod" ]] && continue
      LAST_POD="$pod"; LAST_CONTAINER="$container"
      active=$(kubectl -n "$NAMESPACE" exec "$pod" -c "$container" -- \
          wget -q -O - http://localhost:9093/reload/status 2>/dev/null | \
          python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("active_config_sha256", ""))
except Exception:
    pass' 2>/dev/null || true)
      [[ -n "$active" ]] && LAST_SHA="$active"
      if [[ "$active" == "$WANT_SHA" ]]; then
        echo "[*] Active config SHA matches on pod $pod ($container) — patch is live."
        exit 0
      fi
    done <<< "$SIDECAR_PODS"
  fi
  sleep 3
done

if ! $SAW_SIDECAR; then
  echo "ERROR: could not find an authbridge sidecar container in pods of $AGENT_NAME." >&2
  echo "       Looked for: ${AUTHBRIDGE_CANDIDATES[*]}." >&2
  echo "       Pods and their containers:" >&2
  kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name="$AGENT_NAME" \
      -o jsonpath='{range .items[*]}{"         "}{.metadata.name}{": "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' >&2 2>/dev/null || true
  exit 1
fi

echo "ERROR: authbridge active config did not match patched SHA within ${TIMEOUT}s." >&2
echo "       want:        $WANT_SHA" >&2
echo "       last active: ${LAST_SHA:-<none>}" >&2
if [[ -n "$LAST_POD" ]]; then
  echo "       Last 20 lines of the $LAST_CONTAINER container (pod $LAST_POD):" >&2
  kubectl -n "$NAMESPACE" logs "$LAST_POD" -c "$LAST_CONTAINER" --tail=20 >&2 || true
fi
echo >&2
echo "       Likely causes:" >&2
echo "         - ConfigMap parse error (look for 'reload failed' above)" >&2
echo "         - kubelet sync slow (retry with a higher timeout arg)" >&2
echo "         - operator reconciler reverted the patch (re-run apply-pipeline.sh)" >&2
exit 1
