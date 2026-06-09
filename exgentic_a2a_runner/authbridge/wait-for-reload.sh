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
# This script auto-detects which one is in the pod.

set -euo pipefail

NAMESPACE=${1:?namespace required}
AGENT_NAME=${2:?agent name required}
WANT_SHA=${3:?want-sha required}
TIMEOUT=${4:-180}

# Auto-detect the authbridge container name. Sidecars are injected by
# the AuthBridge webhook at pod-admission, so the Deployment spec only
# lists the agent — we have to look at a running pod. Try the legacy
# name first (`envoy-proxy`) since most clusters today still run the
# older operator layout; fall back to the post-#411 combined name
# (`authbridge`).
POD_CONTAINERS=$(kubectl -n "$NAMESPACE" get pods \
    -l app.kubernetes.io/name="$AGENT_NAME" \
    -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true)
AUTHBRIDGE_CANDIDATES=(authbridge-proxy authbridge envoy-proxy)
AUTHBRIDGE_CONTAINER=""
for candidate in "${AUTHBRIDGE_CANDIDATES[@]}"; do
  if echo "$POD_CONTAINERS" | tr ' ' '\n' | grep -qx "$candidate"; then
    AUTHBRIDGE_CONTAINER="$candidate"
    break
  fi
done
if [[ -z "$AUTHBRIDGE_CONTAINER" ]]; then
  echo "ERROR: could not find an authbridge sidecar container in pods of $AGENT_NAME." >&2
  echo "       Looked for: ${AUTHBRIDGE_CANDIDATES[*]}." >&2
  echo "       Containers found: ${POD_CONTAINERS:-<none>}" >&2
  exit 1
fi
echo "[*] Authbridge container detected: $AUTHBRIDGE_CONTAINER"

DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "[*] Waiting for authbridge to load the patched config (timeout ${TIMEOUT}s)"
echo "    target SHA: $WANT_SHA"

ACTIVE_SHA=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  ACTIVE_SHA=$(kubectl -n "$NAMESPACE" exec deploy/"$AGENT_NAME" -c "$AUTHBRIDGE_CONTAINER" -- \
      wget -q -O - http://localhost:9093/reload/status 2>/dev/null | \
      python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("active_config_sha256", ""))
except Exception:
    pass' 2>/dev/null || true)
  if [[ "$ACTIVE_SHA" == "$WANT_SHA" ]]; then
    echo "[*] Active config SHA matches — patch is live."
    exit 0
  fi
  sleep 3
done

echo "ERROR: authbridge active config did not match patched SHA within ${TIMEOUT}s." >&2
echo "       want:        $WANT_SHA" >&2
echo "       last active: ${ACTIVE_SHA:-<none>}" >&2
echo "       Last 20 lines of the $AUTHBRIDGE_CONTAINER container:" >&2
kubectl -n "$NAMESPACE" logs deploy/"$AGENT_NAME" -c "$AUTHBRIDGE_CONTAINER" --tail=20 >&2 || true
echo >&2
echo "       Likely causes:" >&2
echo "         - ConfigMap parse error (look for 'reload failed' above)" >&2
echo "         - kubelet sync slow (retry with a higher timeout arg)" >&2
echo "         - operator reconciler reverted the patch (re-run apply-pipeline.sh)" >&2
exit 1
