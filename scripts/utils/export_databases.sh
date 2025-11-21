#!/bin/bash
set -e

# Usage: ./export_databases.sh [OUTPUT_DIR]
# Examples:
#   ./export_databases.sh                    # Exports to $HOME
#   ./export_databases.sh /path/to/output    # Exports to custom directory

# Check if pg_dump is available
if ! command -v pg_dump &> /dev/null; then
    echo "Error: pg_dump utility not found."
    echo "Please install PostgreSQL client tools by running: ./scripts/utils/install_postgres_17.sh from the repository root."
    exit 1
fi

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

enable_port_forward() {
    local DB_TYPE=$1
    
    if [ "$DB_TYPE" = "AIRM" ]; then
        echo "Starting port-forward for AIRM database..."
        kubectl port-forward -n airm pod/$(kubectl get pods -n airm | grep -P "airm-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432 &
        PORT_FORWARD_PID=$!
    elif [ "$DB_TYPE" = "KC" ]; then
        echo "Starting port-forward for Keycloak database..."
        kubectl port-forward -n keycloak pod/$(kubectl get pods -n keycloak | grep -P "keycloak-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432 &
        PORT_FORWARD_PID=$!
    fi
    
    # Wait for port-forward to be ready
    sleep 2
}

disable_port_forward() {
    if [ -n "$PORT_FORWARD_PID" ]; then
        echo "Stopping port-forward (PID: $PORT_FORWARD_PID)..."
        kill $PORT_FORWARD_PID 2>/dev/null || true
        wait $PORT_FORWARD_PID 2>/dev/null || true
        PORT_FORWARD_PID=""
    fi
}

backup_airm_database() {   
    echo "Backing up AIRM database to $AIRM_DB_FILE..."
    enable_port_forward "AIRM"
    export PGPASSWORD=$AIRM_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $AIRM_DB_USERNAME airm > $AIRM_DB_FILE
    unset PGPASSWORD
    disable_port_forward
    echo "AIRM database backup completed."
}

backup_keycloak_database() {
    echo "Backing up Keycloak database to $KEYCLOAK_DB_FILE..."
    enable_port_forward "KC"
    export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak > $KEYCLOAK_DB_FILE
    unset PGPASSWORD
    disable_port_forward
    echo "Keycloak database backup completed."
}

main() {
    get_db_credentials
    backup_airm_database
    backup_keycloak_database
}

# Run main function
main
