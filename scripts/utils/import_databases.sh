#!/bin/bash
set -e

# Usage: ./import_databases.sh <AIRM_DB_FILE|skip> <KEYCLOAK_DB_FILE>
# Example: ./import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql
# Example: ./import_databases.sh skip /path/to/keycloak_backup.sql

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "Error: psql utility not found."
    echo "Please install PostgreSQL client tools by running: ./scripts/utils/install_postgres_17.sh from the repository root."
    exit 1
fi

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <AIRM_DB_FILE|skip> <KEYCLOAK_DB_FILE>"
    echo "  AIRM_DB_FILE: Path to AIRM database backup file or 'skip' to skip AIRM restoration"
    echo "  KEYCLOAK_DB_FILE: Path to Keycloak database backup file"
    exit 1
fi

export AIRM_DB_FILE=$1
export KEYCLOAK_DB_FILE=$2

# Validate files exist (unless skipping AIRM)
if [ "$AIRM_DB_FILE" != "skip" ] && [ ! -f "$AIRM_DB_FILE" ]; then
    echo "ERROR: AIRM database file not found: $AIRM_DB_FILE"
    exit 1
fi

if [ ! -f "$KEYCLOAK_DB_FILE" ]; then
    echo "ERROR: Keycloak database file not found: $KEYCLOAK_DB_FILE"
    exit 1
fi

get_db_credentials() {
    echo "Retrieving database credentials..."
    
    export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
    export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    
    export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
    export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    
    echo "Database credentials retrieved successfully."
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
    
    # Check if port-forward is already active on port 5432
    local EXISTING_PF=$(ps -ef | grep -v grep | grep "kubectl port-forward" | grep "5432:5432" || true)
    
    if [ -n "$EXISTING_PF" ]; then
        # Check if it's for the correct namespace AND pod pattern
        if echo "$EXISTING_PF" | grep -q "\-n $NAMESPACE" && echo "$EXISTING_PF" | grep -q "$POD_PATTERN"; then
            echo "Port-forward for $DB_TYPE database is already active, reusing existing connection..."
            PORT_FORWARD_PID=""
            return 0
        else
            # Port-forward exists but for wrong namespace or pod, kill it
            echo "Port-forward exists for different database, stopping it..."
            local EXISTING_PID=$(echo "$EXISTING_PF" | awk '{print $2}')
            kill $EXISTING_PID 2>/dev/null || true
            sleep 1
        fi
    fi
    
    echo "Starting port-forward for $DB_TYPE database..."
    if [ "$DB_TYPE" = "AIRM" ]; then
        kubectl port-forward -n airm pod/$(kubectl get pods -n airm | grep -P "airm-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432 &
        PORT_FORWARD_PID=$!
    elif [ "$DB_TYPE" = "KC" ]; then
        kubectl port-forward -n keycloak pod/$(kubectl get pods -n keycloak | grep -P "keycloak-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432 &
        PORT_FORWARD_PID=$!
    fi
    
    # Wait for port-forward to be ready
    sleep 2
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

wait_for_pod() {
    local pod_pattern=$1
    local namespace=$2
    local timeout=${3:-300}
    local elapsed=0
    local interval=10
    
    echo "Waiting for pod matching '$pod_pattern' in namespace '$namespace' to be ready..."
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get pods -n $namespace | grep -q "$pod_pattern.*Running"; then
            echo "Pod '$pod_pattern' is running in namespace '$namespace'."
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "Still waiting... (${elapsed}s/${timeout}s)"
    done
    
    echo "ERROR: Timeout waiting for pod '$pod_pattern' in namespace '$namespace'"
    return 1
}

restore_airm_database() {
    if [ "$AIRM_DB_FILE" = "skip" ]; then
        echo "Skipping AIRM database restoration as requested."
        return 0
    fi
    
    echo "Restoring AIRM database..."
    
    # Wait for AIRM database pod to be ready
    wait_for_pod "airm-cnpg-" "airm" 600
    
    # Enable port-forward and restore
    enable_port_forward "AIRM"
    echo "Restoring AIRM database from $AIRM_DB_FILE..."
    PGPASSWORD=$AIRM_DB_PASSWORD psql -h 127.0.0.1 -U $AIRM_DB_USERNAME airm < $AIRM_DB_FILE
    disable_port_forward
    echo "AIRM database restored successfully."
}

restore_keycloak_database() {
    echo "Restoring Keycloak database..."
    
    # Wait for Keycloak database pod to be ready
    wait_for_pod "keycloak-cnpg-" "keycloak" 600
    
    # Enable port-forward and restore
    enable_port_forward "KC"
    echo "Restoring Keycloak database from $KEYCLOAK_DB_FILE..."
    PGPASSWORD=$KEYCLOAK_DB_PASSWORD psql -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak < $KEYCLOAK_DB_FILE
    disable_port_forward
    echo "Keycloak database restored successfully."
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
    echo "Verifying Keycloak database restore..."
        
    # Check Keycloak database pod status
    echo "Checking Keycloak database pod status..."
    kubectl get pods -n keycloak | grep keycloak-cnpg-
    kubectl describe pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg | grep -A 5 "Status:"
    
    echo "Keycloak database restore verification completed."
}

main() {
    set +o history
    get_db_credentials
    restore_airm_database
    restore_keycloak_database
    verify_airm_database_restore
    verify_keycloak_database_restore
    set -o history
}

# Run main function
main
