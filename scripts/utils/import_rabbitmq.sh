#!/usr/bin/env bash
set -euo pipefail

###################################################################################################
#                                                                                                 #
# Description:  Imports RabbitMQ definitions from JSON file                                      #
#                                                                                                 #
# Run with --help flag for usage information and flag descriptions                               #
#                                                                                                 #
###################################################################################################

show_help() {
    cat << 'HELPEOF'
Usage: ./import_rabbitmq.sh <DEFINITIONS_FILE> [OPTIONS]

Description:
  Imports RabbitMQ definitions (exchanges, queues, bindings, policies) from a
  JSON file previously exported using export_rabbitmq.sh. Uses rabbitmqctl
  for reliable import operations.

Arguments:
  DEFINITIONS_FILE        Path to the RabbitMQ definitions JSON file

Options:
  --help                  Display this help message and exit

Behavior:
  - Retrieves RabbitMQ admin credentials from Kubernetes secrets
  - Finds the RabbitMQ pod in the 'airm' namespace
  - Copies definitions file to the pod
  - Imports definitions using rabbitmqctl
  - Cleans up temporary files from the pod

Requirements:
  - kubectl configured and authenticated
  - Access to 'airm' namespace
  - RabbitMQ pod running with label app.kubernetes.io/name=airm-rabbitmq
  - Valid RabbitMQ definitions JSON file

Examples:
  # Import from backup file
  ./import_rabbitmq.sh /path/to/rmq_export_2025-11-27.json

  # Import with full path
  ./import_rabbitmq.sh $HOME/rmq_export_2025-11-27.json

Exit Codes:
  0 - Success (definitions imported successfully)
  1 - Error (missing file, pod not found, import failure)

HELPEOF
    exit 0
}

# Check for --help flag
if [[ "${1:-}" == "--help" ]]; then
    show_help
fi

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <DEFINITIONS_FILE>"
    echo "Run with --help for more information"
    exit 1
fi

DEFINITIONS_FILE="$1"
NAMESPACE="airm"
CONTAINER_NAME="rabbitmq"
TMP_FILE="/tmp/rmq_defs_import.json"

# Validate input file exists
if [[ ! -f "$DEFINITIONS_FILE" ]]; then
    echo "ERROR: Definitions file not found: $DEFINITIONS_FILE"
    exit 1
fi

echo "===================================="
echo "RabbitMQ Import Script"
echo "===================================="
echo ""

# Get RabbitMQ credentials
get_credentials() {
    echo "Retrieving RabbitMQ admin credentials..."
    
    RABBITMQ_USER=$(kubectl get secret airm-rabbitmq-admin -n "$NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode)
    RABBITMQ_PASSWORD=$(kubectl get secret airm-rabbitmq-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)
    
    if [[ -z "$RABBITMQ_USER" ]] || [[ -z "$RABBITMQ_PASSWORD" ]]; then
        echo "ERROR: Failed to retrieve RabbitMQ credentials from secret 'airm-rabbitmq-admin'"
        exit 1
    fi
    
    echo "✓ Credentials retrieved successfully"
    echo ""
}

# Find RabbitMQ pod
find_rabbitmq_pod() {
    echo "Finding RabbitMQ pod in namespace $NAMESPACE..."
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=airm-rabbitmq -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort -V | head -n 1)
    
    # Fallback to generic rabbitmq label if airm-rabbitmq not found
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
}

# Import definitions
import_definitions() {
    echo "Step 1: Copying definitions file to RabbitMQ pod..."
    if ! kubectl cp "$DEFINITIONS_FILE" "${NAMESPACE}/${POD_NAME}:${TMP_FILE}" --container="$CONTAINER_NAME"; then
        echo "ERROR: Failed to copy definitions file to pod"
        exit 1
    fi
    echo "✓ File copied to pod: $TMP_FILE"
    echo ""
    
    echo "Step 2: Importing RabbitMQ definitions using rabbitmqctl..."
    if ! kubectl exec -n "$NAMESPACE" "pod/$POD_NAME" --container="$CONTAINER_NAME" -- \
        rabbitmqctl import_definitions "$TMP_FILE"; then
        echo "ERROR: Failed to import RabbitMQ definitions"
        echo ""
        echo "Cleaning up temporary file..."
        kubectl exec -n "$NAMESPACE" "pod/$POD_NAME" --container="$CONTAINER_NAME" -- \
            rm -f "$TMP_FILE" 2>/dev/null || true
        exit 1
    fi
    echo "✓ Definitions imported successfully"
    echo ""
    
    echo "Step 3: Cleaning up temporary file from pod..."
    kubectl exec -n "$NAMESPACE" "pod/$POD_NAME" --container="$CONTAINER_NAME" -- \
        rm -f "$TMP_FILE" 2>/dev/null || true
    echo "✓ Cleanup complete"
    echo ""
}

# Main execution
main() {
    get_credentials
    find_rabbitmq_pod
    import_definitions
    
    echo "===================================="
    echo "RabbitMQ import completed successfully!"
    echo "===================================="
    echo "Imported from: $DEFINITIONS_FILE"
    echo ""
}

main
