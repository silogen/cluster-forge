#!/bin/bash
set -e

## ⚠️ Important Disclaimers
##
## This is only an example script only, adjust paths and commands as needed for your system.
## This is for illustration purposes only and **not officially supported.**
##
## Always test backup and restore procedures in a safe environment before relying on them in production.
## The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.** 

# Usage: ./import_databases.sh <AIRM_DB_FILE|skip> [KEYCLOAK_DB_FILE] [--port-forward [PORT]]
# Example: ./import_databases.sh /path/to/airm_backup.sql
# Example: ./import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql
# Example: ./import_databases.sh skip /path/to/keycloak_backup.sql
# Example: ./import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql --port-forward
# Example: ./import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql --port-forward 5433

# Global variables
USE_PORT_FORWARD=false
LOCAL_PORT=5432
PORT_FORWARD_PID=""

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <AIRM_DB_FILE|skip> [KEYCLOAK_DB_FILE] [--port-forward [PORT]]"
    echo "  AIRM_DB_FILE: Path to AIRM database backup file or 'skip' to skip AIRM restoration"
    echo "  KEYCLOAK_DB_FILE: Path to Keycloak database backup file (optional, skipped if not provided)"
    echo "  --port-forward: Enable port forwarding (optional)"
    echo "  PORT: Local port to forward to (default: 5432)"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/airm_backup.sql"
    echo "  $0 /path/to/airm_backup.sql /path/to/keycloak_backup.sql"
    echo "  $0 skip /path/to/keycloak_backup.sql"
    exit 1
fi

export AIRM_DB_FILE=$1
export KEYCLOAK_DB_FILE=""

# Check if second argument is a file path or a flag
if [ $# -ge 2 ] && [[ ! "$2" =~ ^-- ]]; then
    export KEYCLOAK_DB_FILE=$2
    shift 2
else
    shift 1
fi

# Parse optional flags
while [ $# -gt 0 ]; do
    case $1 in
        --port-forward)
            USE_PORT_FORWARD=true
            # Check if next argument is a port number
            if [ $# -gt 1 ] && [[ $2 =~ ^[0-9]+$ ]]; then
                LOCAL_PORT=$2
                shift
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate files exist (unless skipping)
if [ "$AIRM_DB_FILE" != "skip" ] && [ ! -f "$AIRM_DB_FILE" ]; then
    echo "ERROR: AIRM database file not found: $AIRM_DB_FILE"
    exit 1
fi

if [ -n "$KEYCLOAK_DB_FILE" ] && [ ! -f "$KEYCLOAK_DB_FILE" ]; then
    echo "ERROR: Keycloak database file not found: $KEYCLOAK_DB_FILE"
    exit 1
fi

get_db_credentials() {
    echo "Retrieving database credentials..."
    
    if [ "$AIRM_DB_FILE" != "skip" ]; then
        export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
        export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    fi
    
    if [ -n "$KEYCLOAK_DB_FILE" ]; then
        export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
        export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    fi
    
    echo "Database credentials retrieved successfully."
}


# Check cluster status and get primary pod
get_cluster_info() {
    local CLUSTER_NAME=$1
    local NAMESPACE=$2
    
    # Get cluster information
    local CLUSTER_INFO=$(kubectl get clusters -n "$NAMESPACE" "$CLUSTER_NAME" -o json 2>/dev/null)
    
    if [ -z "$CLUSTER_INFO" ]; then
        echo "ERROR: Could not find cluster '$CLUSTER_NAME' in namespace '$NAMESPACE'"
        return 1
    fi
    
    # Extract instances and primary
    local INSTANCES=$(echo "$CLUSTER_INFO" | jq -r '.status.instances // 0')
    local PRIMARY=$(echo "$CLUSTER_INFO" | jq -r '.status.targetPrimary // ""')
    
    if [ "$INSTANCES" -eq 0 ]; then
        echo "WARNING: Cluster '$CLUSTER_NAME' has 0 instances - cannot perform restoration"
        return 2
    fi
    
    if [ -z "$PRIMARY" ] || [ "$PRIMARY" = "null" ]; then
        echo "WARNING: Could not determine PRIMARY instance for cluster '$CLUSTER_NAME'"
        return 3
    fi
    
    echo "$PRIMARY"
    return 0
}

# Validate port-forward connection is ready
validate_port_forward() {
    local USERNAME=$1
    local PASSWORD=$2
    local DBNAME=$3
    local MAX_RETRIES=5
    local RETRY_DELAY=3
    local retry=0
    
    echo "Validating port-forward connection..."
    
    while [ $retry -lt $MAX_RETRIES ]; do
        # Try to establish a connection using the actual database credentials
        if PGPASSWORD="$PASSWORD" psql -h 127.0.0.1 -p $LOCAL_PORT -U "$USERNAME" -d "$DBNAME" -c "SELECT 1;" &>/dev/null; then
            echo "✓ Port-forward connection validated"
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $MAX_RETRIES ]; then
            echo "  Connection attempt $retry failed, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
    done
    
    echo "ERROR: Failed to validate port-forward connection after $MAX_RETRIES attempts"
    return 1
}

enable_port_forward() {
    local DB_TYPE=$1
    local POD_NAME=$2
    local NAMESPACE=""
    
    if [ "$DB_TYPE" = "AIRM" ]; then
        NAMESPACE="airm"
    elif [ "$DB_TYPE" = "KC" ]; then
        NAMESPACE="keycloak"
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
    
    if [ -z "$POD_NAME" ]; then
        echo "ERROR: No pod name provided for port-forward"
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

check_workloads_table() {
    if [ "$AIRM_DB_FILE" = "skip" ]; then
        echo "Skipping workloads table check (AIRM database restoration skipped)."
        return 0
    fi
    
    echo "Checking workloads table in AIRM database..."
    
    # Get primary pod
    local PRIMARY_POD
    PRIMARY_POD=$(get_cluster_info "airm-cnpg" "airm")
    local status=$?
    
    if [ $status -ne 0 ]; then
        echo "Warning: Could not get primary pod for workloads check"
        return 0
    fi
    
    echo "Using primary pod: $PRIMARY_POD"
    
    local WORKLOAD_COUNT
    
    if [ "$USE_PORT_FORWARD" = true ]; then
        enable_port_forward "AIRM" "$PRIMARY_POD"
        if ! validate_port_forward "$AIRM_DB_USERNAME" "$AIRM_DB_PASSWORD" "airm"; then
            disable_port_forward
            echo "Warning: Could not validate port-forward for workloads check"
            return 0
        fi
        # Query via port-forward
        export PGPASSWORD=$AIRM_DB_PASSWORD
        WORKLOAD_COUNT=$(psql -h 127.0.0.1 -p $LOCAL_PORT -U $AIRM_DB_USERNAME -d airm -t -c "SELECT COUNT(*) FROM workloads;" 2>/dev/null | xargs)
        unset PGPASSWORD
        disable_port_forward
    else
        # Query directly in container
        WORKLOAD_COUNT=$(kubectl exec -n airm $PRIMARY_POD --container=postgres -- bash -c "PGPASSWORD=$AIRM_DB_PASSWORD psql -h localhost -U $AIRM_DB_USERNAME -d airm -t -c 'SELECT COUNT(*) FROM workloads;' 2>/dev/null | xargs")
    fi
    
    if [ -z "$WORKLOAD_COUNT" ]; then
        echo "Info: Could not query workloads table. Table may not exist yet."
        return 0
    else
        echo "Found $WORKLOAD_COUNT entries in workloads table."
    fi
    
    
    if [ "$WORKLOAD_COUNT" -gt 0 ]; then
        echo ""
        echo "⚠️  WARNING: The public.workloads table contains $WORKLOAD_COUNT entries."
        echo "⚠️  Restoring the database will OVERWRITE this data."
        echo ""
        read -p "Do you want to continue with the database restoration? (yes/no): " -r REPLY
        echo ""
        
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Database restoration cancelled by user."
            exit 0
        fi
        
        echo "Continuing with database restoration..."
    fi
    
    # Delete and wait for CNPG clusters to be recreated for clean restore
    echo "Deleting CNPG clusters for clean restore..."
    
    if [ "$AIRM_DB_FILE" != "skip" ]; then
        echo "Deleting AIRM CNPG cluster..."
        kubectl delete cluster airm-cnpg -n airm --ignore-not-found=true
        echo "Waiting for AIRM CNPG cluster to be recreated..."
        kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=airm-cnpg -n airm --timeout=300s
    fi
    
    if [ -n "$KEYCLOAK_DB_FILE" ]; then
        echo "Deleting Keycloak CNPG cluster..."
        kubectl delete cluster keycloak-cnpg -n keycloak --ignore-not-found=true
        echo "Waiting for Keycloak CNPG cluster to be recreated..."
        kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=keycloak-cnpg -n keycloak --timeout=300s
    if
}

restore_airm_database() {
    if [ "$AIRM_DB_FILE" = "skip" ]; then
        echo "Skipping AIRM database restoration."
        return 0
    fi
    
    echo "Restoring AIRM database from $AIRM_DB_FILE..."
    
    # Wait for the PostgreSQL pod to be ready
    echo "Waiting for AIRM database pod to be ready..."
    kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=airm-cnpg -n airm --timeout=300s
    
    # Get primary pod
    local PRIMARY_POD
    PRIMARY_POD=$(get_cluster_info "airm-cnpg" "airm")
    local status=$?
    
    if [ $status -ne 0 ]; then
        echo "Error: Could not determine primary pod for AIRM cluster"
        exit 1
    fi
    
    echo "Using primary pod: $PRIMARY_POD"
    
    local restore_status
    
    if [ "$USE_PORT_FORWARD" = true ]; then
        enable_port_forward "AIRM" "$PRIMARY_POD"
        if ! validate_port_forward "$AIRM_DB_USERNAME" "$AIRM_DB_PASSWORD" "airm"; then
            disable_port_forward
            echo "Error: Could not validate port-forward connection to AIRM database"
            exit 1
        fi
        
        # Restore via port-forward
        export PGPASSWORD=$AIRM_DB_PASSWORD
        psql -h 127.0.0.1 -p $LOCAL_PORT -U $AIRM_DB_USERNAME airm < $AIRM_DB_FILE
        restore_status=$?
        unset PGPASSWORD
        disable_port_forward
    else
        # Restore directly in container
        echo "Executing restore in container..."
        kubectl exec -i -n airm $PRIMARY_POD --container=postgres -- bash -c "PGPASSWORD='$AIRM_DB_PASSWORD' psql -h localhost -U $AIRM_DB_USERNAME -d airm" < "$AIRM_DB_FILE"
        restore_status=$?
    fi
    
    if [ $restore_status -eq 0 ]; then
        echo "AIRM database restored successfully."
        
        # Restart AIRM deployments to pick up restored data
        echo "Restarting AIRM deployments..."
        kubectl rollout restart deployment airm-api -n airm
    else
        echo "Failed to restore AIRM database."
        exit 1
    fi
}

restore_keycloak_database() {
    if [ "$KEYCLOAK_DB_FILE" = "skip" ]; then
        echo "Skipping Keycloak database restoration."
        return 0
    fi
    
    echo "Restoring Keycloak database from $KEYCLOAK_DB_FILE..."
    
    # Wait for the PostgreSQL pod to be ready
    echo "Waiting for Keycloak database pod to be ready..."
    kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=keycloak-cnpg -n keycloak --timeout=300s
    
    # Get primary pod
    local PRIMARY_POD
    PRIMARY_POD=$(get_cluster_info "keycloak-cnpg" "keycloak")
    local status=$?
    
    if [ $status -ne 0 ]; then
        echo "Error: Could not determine primary pod for Keycloak cluster"
        exit 1
    fi
    
    echo "Using primary pod: $PRIMARY_POD"
    
    local restore_status
    
    if [ "$USE_PORT_FORWARD" = true ]; then
        enable_port_forward "KEYCLOAK" "$PRIMARY_POD"
        if ! validate_port_forward "$KEYCLOAK_DB_USERNAME" "$KEYCLOAK_DB_PASSWORD" "keycloak"; then
            disable_port_forward
            echo "Error: Could not validate port-forward connection to Keycloak database"
            exit 1
        fi
        
        # Restore via port-forward
        export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
        psql -h 127.0.0.1 -p $LOCAL_PORT -U $KEYCLOAK_DB_USERNAME keycloak < $KEYCLOAK_DB_FILE
        restore_status=$?
        unset PGPASSWORD
        disable_port_forward
    else
        # Restore directly in container
        echo "Executing restore in container..."
        kubectl exec -i -n keycloak $PRIMARY_POD --container=postgres -- bash -c "PGPASSWORD='$KEYCLOAK_DB_PASSWORD' psql -h localhost -U $KEYCLOAK_DB_USERNAME -d keycloak" < "$KEYCLOAK_DB_FILE"
        restore_status=$?
    fi
    
    if [ $restore_status -eq 0 ]; then
        echo "Keycloak database restored successfully."
        
        # Restart Keycloak deployments to pick up restored data
        echo "Restarting Keycloak deployments..."
        kubectl rollout restart deployment keycloak -n keycloak
    else
        echo "Failed to restore Keycloak database."
        exit 1
    fi
}

verify_airm_database_restore() {
    if [ "$AIRM_DB_FILE" = "skip" ]; then
        echo "Skipping AIRM database verification."
    else
        echo "Verifying AIRM database restore..."
        
        # Check AIRM database pod status
        echo "Checking AIRM database pod status..."
        kubectl get pods -n airm | grep airm-cnpg-
        kubectl describe pod -n airm -l cnpg.io/cluster=airm-cnpg | grep -A 5 "Status:"
        
        echo "AIRM database restore verification completed."
    fi
}

verify_keycloak_database_restore() {
    if [ -z "$KEYCLOAK_DB_FILE" ]; then
        echo "Skipping Keycloak database verification."
        return 0
    fi
    
    echo "Verifying Keycloak database restore..."
        
    # Check Keycloak database pod status
    echo "Checking Keycloak database pod status..."
    kubectl get pods -n keycloak | grep keycloak-cnpg-
    kubectl describe pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg | grep -A 5 "Status:"
    
    echo "Keycloak database restore verification completed."
}

main() {
    get_db_credentials  # Get new credentials after reinstall
    
    # Trap to ensure cleanup on exit
    trap disable_port_forward EXIT INT TERM
    
    # Check workloads table before restoration
    check_workloads_table
    
    restore_airm_database
    restore_keycloak_database
    verify_airm_database_restore
    verify_keycloak_database_restore
}

# Run main function
main
