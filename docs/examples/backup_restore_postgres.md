# PostgreSQL Database Backup & Restore Commands

This document provides the step-by-step commands for backing up and restoring AIRM and Keycloak PostgreSQL databases.

**Note:** This is an example process specific to Ubuntu/Linux environments. Adjust paths and commands as needed for your system.


## Prerequisites

- Shell access to a machine with `kubectl` configured for the target Kubernetes cluster
- Access to the AIRM / Keycloak namespaces in the Kubernetes cluster
- Sufficient local disk space for database backups (database size + 20% recommended)

## Database Backup

```bash
# Set backup directory
# Creates a directory in your home folder to store database backups
BACKUP_DIR="$HOME/db_backups"
mkdir -p "$BACKUP_DIR"
BACKUP_DATE=$(date +%Y-%m-%d)

# Get AIRM database credentials
# Retrieves the database username, password, and database name from Kubernetes secrets
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Get Keycloak database credentials
# Retrieves the database username, password, and database name from Kubernetes secrets
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary AIRM pod
# Locates the primary PostgreSQL pod for AIRM (important for multi-replica setups)
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Find primary Keycloak pod
# Locates the primary PostgreSQL pod for Keycloak (important for multi-replica setups)
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Backup AIRM database
# Step 1: Run pg_dump inside the container to create a SQL backup file
kubectl exec -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' pg_dump -U '$AIRM_USER' -d '$AIRM_DB' > /var/lib/postgresql/data/airm_backup.sql"
# Step 2: Copy the backup file from the container to your local machine
kubectl cp -n airm "$AIRM_POD":/var/lib/postgresql/data/airm_backup.sql "$BACKUP_DIR/airm_db_backup_$BACKUP_DATE.sql"
# Step 3: Remove the temporary file from the container to free up space
kubectl exec -n airm "$AIRM_POD" -- rm /var/lib/postgresql/data/airm_backup.sql

# Backup Keycloak database
# Step 1: Run pg_dump inside the container to create a SQL backup file
kubectl exec -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' pg_dump -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' > /var/lib/postgresql/data/keycloak_backup.sql"
# Step 2: Copy the backup file from the container to your local machine
kubectl cp -n keycloak "$KEYCLOAK_POD":/var/lib/postgresql/data/keycloak_backup.sql "$BACKUP_DIR/keycloak_db_backup_$BACKUP_DATE.sql"
# Step 3: Remove the temporary file from the container to free up space
kubectl exec -n keycloak "$KEYCLOAK_POD" -- rm /var/lib/postgresql/data/keycloak_backup.sql

# Display completed backups
echo "Backups completed:"
ls -lh "$BACKUP_DIR"/*_$BACKUP_DATE.sql
```

## Database Restore

```bash
# Set paths to your backup files
# Update the date in the filename to match your backup files
AIRM_BACKUP="$HOME/db_backups/airm_db_backup_2025-12-03.sql"
KEYCLOAK_BACKUP="$HOME/db_backups/keycloak_db_backup_2025-12-03.sql"

# Get AIRM database credentials
# Retrieves the current database credentials from Kubernetes secrets
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Get Keycloak database credentials
# Retrieves the current database credentials from Kubernetes secrets
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary AIRM pod
# Locates the primary PostgreSQL pod for AIRM
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Find primary Keycloak pod
# Locates the primary PostgreSQL pod for Keycloak
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Wait for pods to be ready
# Ensures pods are fully operational before attempting restore (waits up to 5 minutes)
kubectl wait --for=condition=ready pod -n airm "$AIRM_POD" --timeout=300s
kubectl wait --for=condition=ready pod -n keycloak "$KEYCLOAK_POD" --timeout=300s

# Restore AIRM database
# Pipes the SQL backup file directly into psql running in the container
# This will overwrite existing data in the database
cat "$AIRM_BACKUP" | kubectl exec -i -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' psql -U '$AIRM_USER' -d '$AIRM_DB' -h localhost"

# Restore Keycloak database
# Pipes the SQL backup file directly into psql running in the container
# This will overwrite existing data in the database
cat "$KEYCLOAK_BACKUP" | kubectl exec -i -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' psql -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' -h localhost"

# Restart AIRM deployments to pick up restored data
# Forces all AIRM pods to restart and reload the restored database state
kubectl rollout restart deployment -n airm

echo "Database restore completed"
```

## What These Commands Do

**Backup Process:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for AIRM and Keycloak databases
3. Executes `pg_dump` inside each pod to create backups
4. Copies the backup files to your local machine
5. Cleans up temporary files from the containers
6. Creates timestamped backup files: `airm_db_backup_YYYY-MM-DD.sql` and `keycloak_db_backup_YYYY-MM-DD.sql`

**Restore Process:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for each database
3. Waits for pods to be ready
4. Pipes SQL backup files directly into the database containers
5. Restarts AIRM deployments to apply the restored data
