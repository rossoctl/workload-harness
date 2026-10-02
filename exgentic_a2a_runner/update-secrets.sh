#!/bin/bash
# Update Kubernetes secrets for OPENAI_API_KEY and HF_TOKEN
# Usage: ./update-secrets.sh [--namespace <ns>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

NAMESPACE="team1"

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--namespace <ns>]"
            exit 1
            ;;
    esac
done

echo "Updating secrets in namespace: $NAMESPACE"
echo ""

# Update openai-secret
echo "Updating openai-secret with OPENAI_API_KEY..."
if [ -z "$OPENAI_API_KEY" ]; then
    echo "Warning: OPENAI_API_KEY is not set — skipping"
else
    ENCODED_KEY=$(echo -n "$OPENAI_API_KEY" | base64)
    # Patch when the secret already exists, create it otherwise. Stderr is
    # captured (2>&1 >/dev/null) so a real failure reports why kubectl refused
    # — RBAC denial, missing namespace, missing /data/apikey key, ...
    if kubectl get secret openai-secret -n "$NAMESPACE" >/dev/null 2>&1; then
        if PATCH_ERR=$(kubectl patch secret openai-secret -n "$NAMESPACE" --type='json' -p="[
          {
            \"op\": \"replace\",
            \"path\": \"/data/apikey\",
            \"value\": \"$ENCODED_KEY\"
          }
        ]" 2>&1 >/dev/null); then
            echo "✓ openai-secret updated"
        else
            echo "Warning: Could not update openai-secret (kubectl patch secret openai-secret -n $NAMESPACE failed)"
            [ -n "$PATCH_ERR" ] && echo "  Reason: $PATCH_ERR"
        fi
    else
        # Key must be "apikey" — that is what k8s/job.yaml's secretKeyRef reads.
        if CREATE_ERR=$(kubectl create secret generic openai-secret -n "$NAMESPACE" \
            --from-literal=apikey="$OPENAI_API_KEY" 2>&1 >/dev/null); then
            echo "✓ openai-secret created"
        else
            echo "Warning: Could not create openai-secret (kubectl create secret generic openai-secret -n $NAMESPACE failed)"
            [ -n "$CREATE_ERR" ] && echo "  Reason: $CREATE_ERR"
        fi
    fi
fi

echo ""

# Update hf-secret
echo "Updating hf-secret with HF_TOKEN..."
if [ -z "$HF_TOKEN" ]; then
    echo "Warning: HF_TOKEN is not set — skipping"
else
    ENCODED_HF_TOKEN=$(echo -n "$HF_TOKEN" | base64)
    if kubectl get secret hf-secret -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl patch secret hf-secret -n "$NAMESPACE" --type='json' -p="[
          {
            \"op\": \"replace\",
            \"path\": \"/data/hf-token\",
            \"value\": \"$ENCODED_HF_TOKEN\"
          }
        ]" 2>/dev/null && echo "✓ hf-secret updated" || echo "Warning: Could not update hf-secret"
    else
        kubectl create secret generic hf-secret -n "$NAMESPACE" \
            --from-literal=hf-token="$HF_TOKEN" 2>/dev/null && echo "✓ hf-secret created" || echo "Warning: Could not create hf-secret"
    fi
fi

echo ""
echo "Done."
