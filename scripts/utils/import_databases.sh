#!/bin/bash
set -e

# Global variables
export CURRENT_DATE=$(date +%Y-%m-%d)
export AIRM_DB_FILE=$HOME/airm_db_backup_$CURRENT_DATE.sql
export KEYCLOAK_DB_FILE=$HOME/keycloak_db_backup_$CURRENT_DATE.sql

get_db_credentials() {
    echo "Retrieving database credentials..."
    
    export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
    export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    
    export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
    export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    
    echo "Database credentials retrieved successfully."
}

restore_airm_database() {
    echo "Restoring AIRM database..."
    
    # Wait for AIRM database pod to be ready
    wait_for_pod "airm-cnpg-1" "airm" 600
    
    # Restore AIRM database
    echo "Restoring AIRM database from $AIRM_DB_FILE..."
    export PGPASSWORD=$AIRM_DB_PASSWORD
    psql -h 127.0.0.1 -U $AIRM_DB_USERNAME airm < $AIRM_DB_FILE
    unset PGPASSWORD
    echo "AIRM database restored successfully."
    
    # Wait for Keycloak database pod to be ready
    wait_for_pod "keycloak-cnpg-1" "keycloak" 600
    
    # Restore Keycloak database
    echo "Restoring Keycloak database from $KEYCLOAK_DB_FILE..."
    export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
    psql -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak < $KEYCLOAK_DB_FILE
    unset PGPASSWORD
    echo "Keycloak database restored successfully."
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

verify_airm_database_restore() {
    echo "Verifying AIRM database restore..."
    
    # Check AIRM database pod status
    echo "Checking AIRM database pod status..."
    kubectl get pods -n airm | grep airm-cnpg-1
    kubectl describe pod -n airm -l cnpg.io/cluster=airm-cnpg | grep -A 5 "Status:"
    
    echo "AIRM database restore verification completed."
}

verify_airm_database_restore() {
    echo "Verifying Keycloak database restore..."
        
    # Check Keycloak database pod status
    echo "Checking Keycloak database pod status..."
    kubectl get pods -n keycloak | grep keycloak-cnpg-1
    kubectl describe pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg | grep -A 5 "Status:"
    
    echo "Database restore verification completed."
}

main() {
    get_db_credentials  # Get new credentials after reinstall
    restore_airm_databases
    restore_keycloak_databases
    verify_database_restore
}