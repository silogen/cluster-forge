#!/bin/bash
set -e

# Usage: ./export_dbs_from_container.sh [OUTPUT_DIR]
# Examples:
#   ./export_dbs_from_container.sh                    # Exports to $HOME
#   ./export_dbs_from_container.sh /path/to/output    # Exports to custom directory

# Parse arguments
OUTPUT_DIR=${1:-$HOME}

# Validate output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory '$OUTPUT_DIR' does not exist."
    echo "Please create the directory first: mkdir -p '$OUTPUT_DIR'"
    exit 1
fi

# Global variables
export CURRENT_DATE=$(date +%Y-%m-%d)
export AIRM_DB_FILE=$OUTPUT_DIR/airm_db_backup_$CURRENT_DATE.sql
export KEYCLOAK_DB_FILE=$OUTPUT_DIR/keycloak_db_backup_$CURRENT_DATE.sql

get_db_credentials() {
    echo "Retrieving database credentials..."
    
    export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
    export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    
    export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
    export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    
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
    kubectl exec -n $NAMESPACE $POD_NAME -- bash -c "PGPASSWORD='$PASSWORD' pg_dump --clean -h $HOST -U $USERNAME $DBNAME > $CONTAINER_BACKUP_FILE"
    
    # Copy the backup file from container to host
    echo "Copying backup from container to $OUTPUT_FILE..."
    kubectl cp ${NAMESPACE}/${POD_NAME}:${CONTAINER_BACKUP_FILE} $OUTPUT_FILE
    
    # Clean up the backup file from the container
    echo "Cleaning up backup file from container..."
    kubectl exec -n $NAMESPACE $POD_NAME -- rm -f $CONTAINER_BACKUP_FILE
}

backup_airm_database() {
    echo "Backing up AIRM database to $AIRM_DB_FILE..."
    run_pg_dump "localhost" "$AIRM_DB_USERNAME" "$AIRM_DB_PASSWORD" "airm" "$AIRM_DB_FILE" "airm" "airm-cnpg"
    echo "AIRM database backup completed."
}

backup_keycloak_database() {
    echo "Backing up Keycloak database to $KEYCLOAK_DB_FILE..."
    run_pg_dump "localhost" "$KEYCLOAK_DB_USERNAME" "$KEYCLOAK_DB_PASSWORD" "keycloak" "$KEYCLOAK_DB_FILE" "keycloak" "keycloak-cnpg"
    echo "Keycloak database backup completed."
}

main() {
    set +o history   
    get_db_credentials
    backup_airm_database
    backup_keycloak_database
    set -o history
}

# Run main function
main
