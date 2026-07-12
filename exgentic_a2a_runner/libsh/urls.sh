#!/bin/bash
# Shared URL helper functions for deploy and evaluate scripts.
# Three execution modes, selected in priority order:
#   1. In-cluster (KUBERNETES_SERVICE_HOST set): cluster-local DNS
#   2. OpenShift external (INGRESS_DOMAIN set): https://<svc>-<ns>.<INGRESS_DOMAIN>
#   3. Kind / localtest.me (default): http://<svc>.<ns>.localtest.me:8080
#
# To target an OpenShift cluster from a developer laptop, set INGRESS_DOMAIN
# in your .env (or shell) to the cluster's apps domain, e.g.:
#   INGRESS_DOMAIN=apps.ykt3.hcp.res.ibm.com

kagenti_api_url() {
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://kagenti-backend.kagenti-system.svc.cluster.local:8000"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        echo "https://kagenti-api-kagenti-system.${INGRESS_DOMAIN}"
    else
        echo "http://kagenti-api.localtest.me:8080"
    fi
}

keycloak_api_url() {
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://keycloak-service.keycloak.svc.cluster.local:8080"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        echo "https://keycloak-keycloak.${INGRESS_DOMAIN}"
    else
        echo "http://keycloak.localtest.me:8080"
    fi
}

# $1 = tool name (e.g. exgentic-mcp-gsm8k), $2 = namespace (e.g. team1)
tool_http_url() {
    local tool="$1"
    local ns="${2:-team1}"
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://${tool}-mcp.${ns}.svc.cluster.local:8000"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        echo "https://${tool}-mcp-${ns}.${INGRESS_DOMAIN}"
    else
        echo "http://${tool}.${ns}.localtest.me:8080"
    fi
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
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://${agent}.${ns}.svc.cluster.local:8080"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        echo "https://${agent}-${ns}.${INGRESS_DOMAIN}"
    else
        echo "http://${agent}.${ns}.localtest.me:8080"
    fi
}

mcp_gateway_url() {
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://mcp-gateway-istio.gateway-system.svc.cluster.local:8080"
    elif [ -n "$INGRESS_DOMAIN" ]; then
        echo "https://mcp-gateway-istio-gateway-system.${INGRESS_DOMAIN}"
    else
        echo "http://mcp-gateway-istio.gateway-system.localtest.me:8080"
    fi
}

otel_collector_url() {
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        # Port 8335 is the HTTP/protobuf OTLP port the collector actually binds.
        # 4317 is gRPC-only; curl-based health checks and http/protobuf exporters
        # must use 8335.
        echo "http://otel-collector.kagenti-system.svc.cluster.local:8335"
    else
        echo "http://localhost:4327"
    fi
}

prometheus_url() {
    if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
        echo "http://prometheus.istio-system.svc.cluster.local:9090"
    else
        echo "http://localhost:9191"
    fi
}
