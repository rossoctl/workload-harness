#!/bin/bash
# Shared URL helper functions for deploy and evaluate scripts.
#
# Execution mode is controlled by CLUSTER_MODE (set by --kind / --openshift / --in-cluster):
#   kind        : Kind / localtest.me (default for local development)
#   openshift   : external OpenShift routes; requires INGRESS_DOMAIN to be set
#   in-cluster  : cluster-local DNS (running as a Kubernetes Job pod)
#
# CLUSTER_MODE must be exported by the caller before sourcing this file.
# As a safety net for legacy callers (e.g. the Kubernetes Job that sets
# KUBERNETES_SERVICE_HOST), the variable is derived from env vars when unset:
#   KUBERNETES_SERVICE_HOST set → in-cluster
#   INGRESS_DOMAIN set          → openshift
#   (neither)                   → kind
if [ -z "$CLUSTER_MODE" ]; then
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        CLUSTER_MODE="in-cluster"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        CLUSTER_MODE="openshift"
    else
        CLUSTER_MODE="kind"
    fi
fi

_urls_unsupported_mode() {
    echo "Error: unsupported CLUSTER_MODE '${CLUSTER_MODE}' in ${1}. Must be kind | openshift | in-cluster." >&2
    exit 1
}

kagenti_api_url() {
    case "$CLUSTER_MODE" in
        kind)       echo "http://kagenti-api.localtest.me:8080" ;;
        openshift)  echo "https://kagenti-api-kagenti-system.${INGRESS_DOMAIN}" ;;
        in-cluster) echo "http://kagenti-backend.kagenti-system.svc.cluster.local:8000" ;;
        *)          _urls_unsupported_mode "kagenti_api_url" ;;
    esac
}

keycloak_api_url() {
    case "$CLUSTER_MODE" in
        kind)       echo "http://keycloak.localtest.me:8080" ;;
        openshift)  echo "https://keycloak-keycloak.${INGRESS_DOMAIN}" ;;
        in-cluster) echo "http://keycloak-service.keycloak.svc.cluster.local:8080" ;;
        *)          _urls_unsupported_mode "keycloak_api_url" ;;
    esac
}

# $1 = tool name (e.g. exgentic-mcp-gsm8k), $2 = namespace (e.g. team1)
tool_http_url() {
    local tool="$1"
    local ns="${2:-team1}"
    case "$CLUSTER_MODE" in
        kind)       echo "http://${tool}.${ns}.localtest.me:8080" ;;
        openshift)  echo "https://${tool}-mcp-${ns}.${INGRESS_DOMAIN}" ;;
        in-cluster) echo "http://${tool}-mcp.${ns}.svc.cluster.local:8000" ;;
        *)          _urls_unsupported_mode "tool_http_url" ;;
    esac
}

# Always returns the in-cluster service URL regardless of where the script runs.
# Use this when embedding a URL into a pod spec (env var, config map, etc.)
# so the value is always valid inside the cluster.
tool_k8s_url() {
    local tool="$1"
    local ns="${2:-team1}"
    echo "http://${tool}-mcp.${ns}.svc.cluster.local:8000"
}

# $1 = agent name (e.g. exgentic-a2a-tool-calling-gsm8k), $2 = namespace
agent_http_url() {
    local agent="$1"
    local ns="${2:-team1}"
    case "$CLUSTER_MODE" in
        kind)       echo "http://${agent}.${ns}.localtest.me:8080" ;;
        openshift)  echo "https://${agent}-${ns}.${INGRESS_DOMAIN}" ;;
        in-cluster) echo "http://${agent}.${ns}.svc.cluster.local:8080" ;;
        *)          _urls_unsupported_mode "agent_http_url" ;;
    esac
}

mcp_gateway_url() {
    case "$CLUSTER_MODE" in
        kind)       echo "http://mcp-gateway-istio.gateway-system.localtest.me:8080" ;;
        openshift)  echo "https://mcp-gateway-istio-gateway-system.${INGRESS_DOMAIN}" ;;
        in-cluster) echo "http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080" ;;
        *)          _urls_unsupported_mode "mcp_gateway_url" ;;
    esac
}

otel_collector_url() {
    case "$CLUSTER_MODE" in
        kind)       echo "http://localhost:4327" ;;
        openshift)  echo "http://localhost:4327" ;;
        in-cluster)
            # Port 8335 is the HTTP/protobuf OTLP port the collector actually binds.
            # 4317 is gRPC-only; curl-based health checks and http/protobuf exporters
            # must use 8335.
            echo "http://otel-collector.kagenti-system.svc.cluster.local:8335" ;;
        *)          _urls_unsupported_mode "otel_collector_url" ;;
    esac
}

prometheus_url() {
    case "$CLUSTER_MODE" in
        kind)       echo "http://localhost:9191" ;;
        openshift)  echo "http://localhost:9191" ;;
        in-cluster) echo "http://prometheus.istio-system.svc.cluster.local:9090" ;;
        *)          _urls_unsupported_mode "prometheus_url" ;;
    esac
}
