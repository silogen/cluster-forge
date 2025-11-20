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

backup_airm_database() {   
    echo "Backing up AIRM database to $AIRM_DB_FILE..."
    export PGPASSWORD=$AIRM_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $AIRM_DB_USERNAME airm > $AIRM_DB_FILE
    unset PGPASSWORD
    echo "AIRM database backup completed."
}

backup_keycloak_database() {
    # Backup Keycloak database
    echo "Backing up Keycloak database to $KEYCLOAK_DB_FILE..."
    export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak > $KEYCLOAK_DB_FILE
    unset PGPASSWORD
    echo "Keycloak database backup completed."
}

main() {
    get_db_credentials
    backup_airm_database
    backup_keycloak_database
}

# Run main function
main