#!/usr/bin/env bash
set -euo pipefail

## ⚠️ Important Disclaimers
##
## This is only an example script only, adjust paths and commands as needed for your system.
## This is for illustration purposes only and **not officially supported.**
##
## Always test backup and restore procedures in a safe environment before relying on them in production.
## The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.** 

###################################################################################################
#                                                                                                 #
# Description:  Exports RabbitMQ definitions to JSON file                                        #
#                                                                                                 #
# Run with --help flag for usage information and flag descriptions                               #
#                                                                                                 #
###################################################################################################

show_help() {
    cat << 'HELPEOF'
Usage: ./export_rabbitmq.sh [OUTPUT_DIR] [OPTIONS]

Description:
  Exports RabbitMQ definitions (exchanges, queues, bindings, policies) from the
  cluster to a timestamped JSON file. Useful for backup and migration purposes.

Arguments:
  OUTPUT_DIR              Directory to save the export file (default: $HOME)

Options:
  --help                  Display this help message and exit

Behavior:
  - Finds the RabbitMQ pod in the 'airm' namespace
  - Exports definitions using rabbitmqctl inside the pod
  - Copies the export file to the specified local directory
  - Cleans up temporary files from the pod
  - Creates timestamped files: rmq_export_YYYY-MM-DD.json

Requirements:
  - kubectl configured and authenticated
  - Access to 'airm' namespace
  - RabbitMQ pod running with label app.kubernetes.io/name=airm-rabbitmq

Output Files:
  - rmq_export_YYYY-MM-DD.json

Examples:
  # Export to home directory (default)
  ./export_rabbitmq.sh

  # Export to custom directory
  ./export_rabbitmq.sh /path/to/backups

Exit Codes:
  0 - Success (export completed successfully)
  1 - Error (missing pod, export failure)

HELPEOF
    exit 0
}

# Check for --help flag
if [[ "${1:-}" == "--help" ]]; then
    show_help
fi

NAMESPACE="airm"
CONTAINER_NAME="rabbitmq"
TMP_FILE="/tmp/rmq_defs.json"

# Default output location
OUTPUT_DIR="${1:-$PWD}"
TIMESTAMP=$(date +%Y-%m-%d)
OUTPUT_FILE="${OUTPUT_DIR}/rmq_export_${TIMESTAMP}.json"

echo "===================================="
echo "RabbitMQ Backup Script"
echo "===================================="
echo ""

# Find RabbitMQ pod (use lowest numbered instance)
echo "Finding RabbitMQ pod in namespace $NAMESPACE..."
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=airm-rabbitmq -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort -V | head -n 1)

# Fallback to generic airm label if airm-rabbitmq not found
if [[ -z "$POD_NAME" ]]; then
    echo "  No pods found with label app.kubernetes.io/name=airm-rabbitmq"
    echo "  Trying fallback label app.kubernetes.io/name=rabbitmq..."
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -i rabbitmq | sort -V | head -n 1)
fi

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
echo ""
