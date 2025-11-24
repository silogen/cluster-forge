#!/usr/bin/env bash
set -euo pipefail

# RabbitMQ Backup Script
# Exports RabbitMQ definitions (exchanges, queues, bindings, policies) from the cluster

NAMESPACE="airm"
CONTAINER_NAME="rabbitmq"
TMP_FILE="/tmp/rmq_defs.json"

# Default output location
OUTPUT_DIR="${1:-$HOME}"
TIMESTAMP=$(date +%Y-%m-%d)
OUTPUT_FILE="${OUTPUT_DIR}/rmq_export_${TIMESTAMP}.json"

echo "===================================="
echo "RabbitMQ Backup Script"
echo "===================================="
echo ""

# Find RabbitMQ pod (use lowest numbered instance)
echo "Finding RabbitMQ pod in namespace $NAMESPACE..."
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort -V | head -n 1)

if [[ -z "$POD_NAME" ]]; then
    echo "ERROR: No RabbitMQ pod found in namespace $NAMESPACE"
    echo "Please ensure RabbitMQ is deployed and kubectl is configured correctly."
    exit 1
fi

echo "✓ Found RabbitMQ pod: $POD_NAME"
echo ""

# Verify kubectl access
if ! kubectl get pod -n "$NAMESPACE" "$POD_NAME" &>/dev/null; then
    echo "ERROR: Cannot access pod $POD_NAME in namespace $NAMESPACE"
    echo "Please ensure kubectl is configured and you have access to the cluster."
    exit 1
fi

# Verify output directory exists
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: Output directory does not exist: $OUTPUT_DIR"
    echo "Please create it first or specify a different directory."
    exit 1
fi

echo "Step 1: Exporting RabbitMQ definitions inside the container..."
if ! kubectl exec -n "$NAMESPACE" "pod/$POD_NAME" --container="$CONTAINER_NAME" -- \
    rabbitmqctl export_definitions "$TMP_FILE"; then
    echo "ERROR: Failed to export RabbitMQ definitions"
    exit 1
fi
echo "✓ Definitions exported to $TMP_FILE inside container"
echo ""

echo "Step 2: Copying exported file to local machine..."
if ! kubectl cp "${NAMESPACE}/${POD_NAME}:${TMP_FILE}" "$OUTPUT_FILE" --container="$CONTAINER_NAME"; then
    echo "ERROR: Failed to copy file from container"
    exit 1
fi
echo "✓ File copied to: $OUTPUT_FILE"
echo ""

echo "Step 3: Cleaning up temporary file from container..."
kubectl exec -n "$NAMESPACE" "pod/$POD_NAME" --container="$CONTAINER_NAME" -- \
    rm -f "$TMP_FILE" 2>/dev/null || true
echo "✓ Cleanup complete"
echo ""

echo "===================================="
echo "RabbitMQ backup completed successfully!"
echo "===================================="
echo "Backup file: $OUTPUT_FILE"
echo ""
echo "To restore this backup, use:"
echo "  ./scripts/utils/import_rabbitmq.sh $OUTPUT_FILE"
