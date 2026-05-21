#!/bin/bash
# Block until the authbridge sidecar's filesystem-watch reloader
# observes the patched ConfigMap and rebuilds the pipeline (logs
# `reloader: pipelines swapped`). Times out after $TIMEOUT seconds.
#
# Usage: wait-for-reload.sh <namespace> <agent-name> [timeout-seconds]
#
# kubelet syncs ConfigMap projected-volume contents on roughly a 60s
# cycle, so the reload typically lands within 5-90s of the patch.

set -euo pipefail

NAMESPACE=${1:?namespace required}
AGENT_NAME=${2:?agent name required}
TIMEOUT=${3:-120}

DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "[*] Waiting for authbridge to hot-reload (timeout ${TIMEOUT}s) ..."

# --since-time only matches lines from now onwards, so a reload that
# fired earlier in the pod's lifetime can't false-positive this wait.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

while [[ $(date +%s) -lt $DEADLINE ]]; do
  if kubectl -n "$NAMESPACE" logs deploy/"$AGENT_NAME" -c authbridge-proxy \
        --since-time="$SINCE" 2>/dev/null \
        | grep -F "reloader: pipelines swapped" >/dev/null; then
    echo "[*] Reload confirmed."
    exit 0
  fi
  sleep 3
done

echo "ERROR: authbridge did not log 'reloader: pipelines swapped' within ${TIMEOUT}s." >&2
echo "       Last 20 lines of the authbridge container:" >&2
kubectl -n "$NAMESPACE" logs deploy/"$AGENT_NAME" -c authbridge-proxy --tail=20 >&2 || true
echo >&2
echo "       Likely causes:" >&2
echo "         - ConfigMap parse error (check 'reload failed' lines above)" >&2
echo "         - kubelet hasn't synced the projected volume yet (re-run the script)" >&2
echo "         - operator restarted and overwrote your patch (re-run apply-ibac.sh)" >&2
exit 1
