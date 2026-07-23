#!/bin/bash
# Minimal manual deploy of the gsm8k benchmark image to the current cluster.
# No Keycloak, no Rossoctl API, no auth — just a Deployment + Service.
# Usage: ./deploy-gsm8k-local.sh

set -euo pipefail

# Image (matches deploy-benchmark.sh defaults)
EXGENTIC_REGISTRY="${EXGENTIC_REGISTRY:-ghcr.io/exgentic}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BENCHMARK_NAME="gsm8k"
IMAGE_NAME="${EXGENTIC_REGISTRY}/exgentic-mcp-${BENCHMARK_NAME}:${IMAGE_TAG}"

NAMESPACE="${NAMESPACE:-default}"
NAME="exgentic-mcp-${BENCHMARK_NAME}"

echo "Deploying $NAME"
echo "  image:     $IMAGE_NAME"
echo "  namespace: $NAMESPACE"
echo "  context:   $(kubectl config current-context)"
echo ""

if [ "$NAMESPACE" != "default" ]; then
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      containers:
      - name: mcp
        image: ${IMAGE_NAME}
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8000
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: "4"
            memory: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${NAME}
spec:
  selector:
    app: ${NAME}
  ports:
  - name: http
    port: 8000
    targetPort: 8000
    protocol: TCP
EOF

echo ""
echo "Waiting for rollout..."
kubectl rollout status deployment/"$NAME" -n "$NAMESPACE" --timeout=300s

echo ""
echo "Done."
kubectl get deployment,svc,pod -n "$NAMESPACE" -l app="$NAME"
