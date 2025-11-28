#!/bin/bash
set -e

###################################################################################################
#                                                                                                 #
# Description:  Exports PostgreSQL databases from Kubernetes pods to local SQL files             #
#                                                                                                 #
# Run with --help flag for usage information and flag descriptions                               #
#                                                                                                 #
###################################################################################################

show_help() {
    cat << 'HELPEOF'
Usage: ./export_databases.sh [OUTPUT_DIR] [OPTIONS]

Description:
  Exports AIRM and Keycloak PostgreSQL databases from Kubernetes pods to local
  SQL dump files. Creates timestamped backup files with automatic versioning
  to prevent overwrites.

Arguments:
  OUTPUT_DIR              Directory to save database backups (default: $HOME)

Options:
  --help                  Display this help message and exit
  
  --port-forward [PORT]   Use kubectl port-forward instead of direct pod exec.
                          Optional PORT argument specifies local port (default: 5432).
                          Useful when direct pod access is restricted or for debugging.
  
  --airm                  Backup only the AIRM database (mutually exclusive with --keycloak)
  
  --keycloak              Backup only the Keycloak database (mutually exclusive with --airm)

Behavior:
  - Creates timestamped SQL dump files: *_backup_YYYY-MM-DD.sql
  - Automatically versions files if same-day backup exists (_02, _03, etc.)
  - Retrieves database credentials from Kubernetes secrets
  - Runs pg_dump inside PostgreSQL container
  - Cleans up temporary files from container after export
  - Validates port availability before port-forwarding

Output Files:
  - airm_db_backup_YYYY-MM-DD.sql
  - keycloak_db_backup_YYYY-MM-DD.sql
  - Versioned if exists: *_backup_YYYY-MM-DD_02.sql, *_03.sql, etc.

Examples:
  # Export to home directory (default)
  ./export_databases.sh

  # Export to custom directory
  ./export_databases.sh /path/to/backups

  # Use port-forward with default port 5432
  ./export_databases.sh /path/to/backups --port-forward

  # Use port-forward with custom port
  ./export_databases.sh /path/to/backups --port-forward 5433

Exit Codes:
  0 - Success (databases exported successfully)
  1 - Error (missing pod, port conflict, export failure)
HELPEOF
    exit 0
}

# Global variables
USE_PORT_FORWARD=false
LOCAL_PORT=5432
PORT_FORWARD_PID=""
BACKUP_AIRM=true
BACKUP_KEYCLOAK=true

# Parse arguments
if [[ "$1" == "--help" ]]; then
    show_help
fi

OUTPUT_DIR=${1:-$HOME}
# Remove trailing slash if present
OUTPUT_DIR=${OUTPUT_DIR%/}
shift || true

# Parse optional flags
while [ $# -gt 0 ]; do
    case $1 in
        --help)
            show_help
            ;;
        --port-forward)
            USE_PORT_FORWARD=true
            # Check if next argument is a port number
            if [ $# -gt 1 ] && [[ $2 =~ ^[0-9]+$ ]]; then
                LOCAL_PORT=$2
                shift
            fi
            shift
            ;;
        --airm)
            if [ "$BACKUP_KEYCLOAK" = false ]; then
                echo "Error: Cannot specify both --airm and --keycloak"
                exit 1
            fi
            BACKUP_AIRM=true
            BACKUP_KEYCLOAK=false
            shift
            ;;
        --keycloak)
            if [ "$BACKUP_AIRM" = false ]; then
                echo "Error: Cannot specify both --airm and --keycloak"
                exit 1
            fi
            BACKUP_AIRM=false
            BACKUP_KEYCLOAK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

# Validate output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory '$OUTPUT_DIR' does not exist."
    echo "Please create the directory first: mkdir -p '$OUTPUT_DIR'"
    exit 1
fi

# Get current kubectl context cluster name
get_cluster_prefix() {
    local CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "default")
    local CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CURRENT_CONTEXT')].context.cluster}" 2>/dev/null || echo "default")
    
    # If cluster name is "default", return empty prefix
    if [ "$CLUSTER_NAME" = "default" ]; then
        echo ""
    else
        echo "${CLUSTER_NAME}_"
    fi
}

# Function to get versioned filename if file exists
get_versioned_filename() {
    local base_file=$1
    local output_file=$base_file
    
    if [ -f "$output_file" ]; then
        local counter=2
        local base_name="${base_file%.sql}"
        
        while [ -f "${base_name}_$(printf '%02d' $counter).sql" ]; do
            counter=$((counter + 1))
        done
        
        output_file="${base_name}_$(printf '%02d' $counter).sql"
        echo "$output_file"
        return 0
    fi
    
    echo "$output_file"
    return 0
}

# Global variables
export CURRENT_DATE=$(date +%Y-%m-%d)
CLUSTER_PREFIX=$(get_cluster_prefix)
AIRM_DB_FILE_BASE=$OUTPUT_DIR/${CLUSTER_PREFIX}airm_db_backup_$CURRENT_DATE.sql
KEYCLOAK_DB_FILE_BASE=$OUTPUT_DIR/${CLUSTER_PREFIX}keycloak_db_backup_$CURRENT_DATE.sql

export AIRM_DB_FILE=$(get_versioned_filename "$AIRM_DB_FILE_BASE")
export KEYCLOAK_DB_FILE=$(get_versioned_filename "$KEYCLOAK_DB_FILE_BASE")

get_db_credentials() {
    if [ "$BACKUP_AIRM" = true ]; then
        echo "Retrieving AIRM database credentials..."
        export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
        export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    fi
    
    if [ "$BACKUP_KEYCLOAK" = true ]; then
        echo "Retrieving Keycloak database credentials..."
        export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
        export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    fi
    
    echo "Database credentials retrieved successfully."
}

run_pg_dump() {
    local HOST=$1
    local USERNAME=$2
    local PASSWORD=$3
    local DBNAME=$4
    local OUTPUT_FILE=$5
    local NAMESPACE=$6
    local POD_PATTERN=$7
    
    # Get the pod name
    local POD_NAME=$(kubectl get pods -n $NAMESPACE | grep -P "${POD_PATTERN}-\d" | head -1 | awk '{print $1}')
    
    if [ -z "$POD_NAME" ]; then
        echo "Error: Could not find pod matching pattern '${POD_PATTERN}' in namespace '${NAMESPACE}'"
        exit 1
    fi
    
    # Filename for backup inside container
    local CONTAINER_BACKUP_FILE="/var/lib/postgresql/data/$(basename $OUTPUT_FILE)"
    
    echo "Running pg_dump inside pod $POD_NAME..."
    
    # Run pg_dump inside the container
    kubectl exec -n $NAMESPACE $POD_NAME --container='postgres' -- bash -c "PGPASSWORD='$PASSWORD' pg_dump --clean -h $HOST -U $USERNAME $DBNAME > $CONTAINER_BACKUP_FILE"
    
    # Copy the backup file from container to host
    echo "Copying backup from container to $OUTPUT_FILE..."
    kubectl cp ${NAMESPACE}/${POD_NAME}:${CONTAINER_BACKUP_FILE} $OUTPUT_FILE --container='postgres'
    
    # Clean up the backup file from the container
    echo "Cleaning up backup file from container..."
    kubectl exec -n $NAMESPACE $POD_NAME -- rm -f $CONTAINER_BACKUP_FILE
}

backup_airm_database() {
    echo "Backing up AIRM database to $AIRM_DB_FILE..."
    
    # Enable port-forward if requested
    if [ "$USE_PORT_FORWARD" = true ]; then
        enable_port_forward "AIRM"
        run_pg_dump "127.0.0.1" "$AIRM_DB_USERNAME" "$AIRM_DB_PASSWORD" "airm" "$AIRM_DB_FILE" "airm" "airm-cnpg"
        disable_port_forward
    else
        run_pg_dump "localhost" "$AIRM_DB_USERNAME" "$AIRM_DB_PASSWORD" "airm" "$AIRM_DB_FILE" "airm" "airm-cnpg"
    fi
    
    echo "AIRM database backup completed."
}

backup_keycloak_database() {
    echo "Backing up Keycloak database to $KEYCLOAK_DB_FILE..."
    
    # Enable port-forward if requested
    if [ "$USE_PORT_FORWARD" = true ]; then
        enable_port_forward "KC"
        run_pg_dump "127.0.0.1" "$KEYCLOAK_DB_USERNAME" "$KEYCLOAK_DB_PASSWORD" "keycloak" "$KEYCLOAK_DB_FILE" "keycloak" "keycloak-cnpg"
        disable_port_forward
    else
        run_pg_dump "localhost" "$KEYCLOAK_DB_USERNAME" "$KEYCLOAK_DB_PASSWORD" "keycloak" "$KEYCLOAK_DB_FILE" "keycloak" "keycloak-cnpg"
    fi
    
    echo "Keycloak database backup completed."
}

enable_port_forward() {
    local DB_TYPE=$1
    local NAMESPACE=""
    local POD_PATTERN=""
    
    if [ "$DB_TYPE" = "AIRM" ]; then
        NAMESPACE="airm"
        POD_PATTERN="airm-cnpg"
    elif [ "$DB_TYPE" = "KC" ]; then
        NAMESPACE="keycloak"
        POD_PATTERN="keycloak-cnpg"
    fi
    
    # Check if port is already in use by any process
    if lsof -Pi :${LOCAL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        local PORT_OWNER_PID=$(lsof -Pi :${LOCAL_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)
        echo "ERROR: Port ${LOCAL_PORT} is already in use by process ID: ${PORT_OWNER_PID}"
        echo ""
        echo "To kill the process using this port, run:"
        echo "  kill ${PORT_OWNER_PID}"
        echo ""
        echo "Or to find more details about the process, run:"
        echo "  ps -p ${PORT_OWNER_PID} -o pid,ppid,cmd"
        echo ""
        echo "To kill all kubectl port-forward processes, run:"
        echo "  pkill -f 'kubectl port-forward'"
        exit 1
    fi
    
    echo "Starting port-forward for $DB_TYPE database on port ${LOCAL_PORT}..."
    local POD_NAME=$(kubectl get pods -n $NAMESPACE | grep -P "${POD_PATTERN}-\d" | head -1 | awk '{print $1}')
    
    if [ -z "$POD_NAME" ]; then
        echo "ERROR: Could not find pod matching pattern '${POD_PATTERN}' in namespace '${NAMESPACE}'"
        exit 1
    fi
    
    kubectl port-forward -n $NAMESPACE pod/$POD_NAME ${LOCAL_PORT}:5432 &
    PORT_FORWARD_PID=$!
    
    # Wait for port-forward to be ready and verify it started successfully
    sleep 2
    
    # Check if the port-forward process is still running
    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        echo "ERROR: Port-forward failed to start. The port ${LOCAL_PORT} may be in use."
        echo ""
        echo "To check what is using the port, run:"
        echo "  lsof -i :${LOCAL_PORT}"
        echo ""
        echo "To kill all kubectl port-forward processes, run:"
        echo "  pkill -f 'kubectl port-forward'"
        exit 1
    fi
    
    echo "Port-forward established successfully (PID: $PORT_FORWARD_PID)"
}

disable_port_forward() {
    # Only kill port-forward if we started it (have a PID)
    if [ -n "$PORT_FORWARD_PID" ]; then
        echo "Stopping port-forward (PID: $PORT_FORWARD_PID)..."
        kill $PORT_FORWARD_PID 2>/dev/null || true
        wait $PORT_FORWARD_PID 2>/dev/null || true
        PORT_FORWARD_PID=""
    fi
}

main() {
    set +o history
    
    # Trap to ensure cleanup on exit
    trap disable_port_forward EXIT INT TERM
    
    get_db_credentials
    #backup_airm_database
    if [ "$BACKUP_KEYCLOAK" = true ]; then
        backup_keycloak_database
    fi
    
    # Summary output
    # Summary output
    echo ""
    echo "========================================"
    echo "Database Export Complete"
    echo "========================================"
    
    if [ "$BACKUP_AIRM" = true ]; then
        echo "AIRM database exported to:"
        echo "  $AIRM_DB_FILE"
    fi
    
    if [ "$BACKUP_AIRM" = true ] && [ "$BACKUP_KEYCLOAK" = true ]; then
        echo ""
    fi
    
    if [ "$BACKUP_KEYCLOAK" = true ]; then
        echo "Keycloak database exported to:"
        echo "  $KEYCLOAK_DB_FILE"
    fi
    
    echo "========================================"
    
    set -o history
}

# Run main function
main
