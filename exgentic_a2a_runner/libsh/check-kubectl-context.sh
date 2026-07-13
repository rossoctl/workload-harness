#!/bin/bash
# Verify kubectl is available and points to the expected cluster for CLUSTER_MODE.
# Must be sourced after CLUSTER_MODE and KUBECTL_BIN are set.
#
# kind       → context must be "kind-kagenti"
# openshift  → context must expose apps.openshift.io API groups
# in-cluster → no check (kubectl is not available inside the Job pod)

check_kubectl_context() {
    if [ "$CLUSTER_MODE" = "in-cluster" ]; then
        if [ -z "$KUBERNETES_SERVICE_HOST" ]; then
            echo "Error: --in-cluster was specified but KUBERNETES_SERVICE_HOST is not set — this script does not appear to be running inside a cluster pod"
            exit 1
        fi
        echo "Running in-cluster — skipping kubectl context check."
        return 0
    fi

    if ! command -v "$KUBECTL_BIN" &>/dev/null; then
        echo "Error: $KUBECTL_BIN is not installed or not in PATH"
        exit 1
    fi

    if ! CURRENT_CONTEXT=$("$KUBECTL_BIN" config current-context 2>/dev/null); then
        echo "Error: Unable to determine current kubectl context"
        exit 1
    fi
    echo "Current kubectl context: $CURRENT_CONTEXT"

    if ! "$KUBECTL_BIN" cluster-info >/dev/null 2>&1; then
        echo "Error: kubectl context '$CURRENT_CONTEXT' is not reachable"
        echo "Hint: refresh your cluster access or set KUBECTL_BIN to another kubectl wrapper"
        exit 1
    fi

    case "$CLUSTER_MODE" in
        kind)
            if [ "$CURRENT_CONTEXT" != "kind-kagenti" ]; then
                echo "Error: --kind requires kubectl context 'kind-kagenti', but current context is '$CURRENT_CONTEXT'"
                exit 1
            fi
            echo "Kind cluster verified (context: $CURRENT_CONTEXT)"
            ;;
        openshift)
            if ! "$KUBECTL_BIN" api-resources --api-group=apps.openshift.io \
                    --no-headers 2>/dev/null | grep -q .; then
                echo "Error: --openshift requires an OpenShift context, but '$CURRENT_CONTEXT' does not expose apps.openshift.io API groups"
                exit 1
            fi
            echo "OpenShift cluster verified (context: $CURRENT_CONTEXT)"
            ;;
        *)
            echo "Error: unsupported CLUSTER_MODE '${CLUSTER_MODE}' in check_kubectl_context. Must be kind | openshift | in-cluster." >&2
            exit 1
            ;;
    esac
}
