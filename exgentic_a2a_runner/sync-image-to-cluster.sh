#!/bin/bash
# Sync a locally-built container image from podman/docker into the kind cluster.
# Called only when --local-image is set; not used for remote registry pulls.
#
# Required env vars:
#   REMOTE_IMAGE_NAME  - the full image reference (e.g. ghcr.io/exgentic/foo:latest)
#
# Optional env vars:
#   KIND_CLUSTER_NAME  - name of the kind cluster (default: kagenti)
#
# Exports on success:
#   IMAGE_NAME         - set to REMOTE_IMAGE_NAME (for callers)

set -e

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kagenti}"

if [ -z "$REMOTE_IMAGE_NAME" ]; then
    echo "Error: REMOTE_IMAGE_NAME is not set"
    exit 1
fi

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Error: Neither podman nor docker found"
    exit 1
fi

echo "Using container runtime: $CONTAINER_CMD"

# Verify the local image exists
if ! $CONTAINER_CMD image inspect "$REMOTE_IMAGE_NAME" &> /dev/null; then
    echo "Error: Local image $REMOTE_IMAGE_NAME not found"
    echo "Please build and tag the image as $REMOTE_IMAGE_NAME first"
    exit 1
fi
echo "✓ Local image found: $REMOTE_IMAGE_NAME"

export IMAGE_NAME="$REMOTE_IMAGE_NAME"

# Check if kind is available
if ! command -v kind &> /dev/null; then
    echo "Error: kind command not found"
    exit 1
fi

# Get local image ID
LOCAL_IMAGE_ID=$($CONTAINER_CMD inspect "$IMAGE_NAME" --format='{{.Id}}' 2>/dev/null || echo "")
if [ -z "$LOCAL_IMAGE_ID" ]; then
    echo "Error: Could not get local image ID for $IMAGE_NAME"
    exit 1
fi
echo "Local image ID: $LOCAL_IMAGE_ID"

# Get cluster image ID via crictl
CLUSTER_IMAGE_ID=$($CONTAINER_CMD exec "${KIND_CLUSTER_NAME}-control-plane" crictl inspecti "$IMAGE_NAME" 2>/dev/null | grep '"id":' | head -1 | sed 's/.*"id": *"\([^"]*\)".*/\1/' || echo "")

# Normalize IDs by removing sha256: prefix if present
LOCAL_IMAGE_ID_NORMALIZED="${LOCAL_IMAGE_ID#sha256:}"
CLUSTER_IMAGE_ID_NORMALIZED="${CLUSTER_IMAGE_ID#sha256:}"

if [ -z "$CLUSTER_IMAGE_ID" ]; then
    echo "Image not found in cluster, syncing..."
    NEED_SYNC=true
elif [ "$LOCAL_IMAGE_ID_NORMALIZED" != "$CLUSTER_IMAGE_ID_NORMALIZED" ]; then
    echo "Cluster image ID: $CLUSTER_IMAGE_ID"
    echo "Images differ, syncing..."
    NEED_SYNC=true
else
    echo "Cluster image ID: $CLUSTER_IMAGE_ID"
    echo "✓ Images match, skipping sync"
    NEED_SYNC=false
fi

if [ "$NEED_SYNC" = true ]; then
    echo "Saving and loading image into kind cluster '$KIND_CLUSTER_NAME'..."
    $CONTAINER_CMD save "$IMAGE_NAME" | kind load image-archive /dev/stdin --name "$KIND_CLUSTER_NAME"
    echo "✓ Image synced to kind cluster '$KIND_CLUSTER_NAME'"
fi
