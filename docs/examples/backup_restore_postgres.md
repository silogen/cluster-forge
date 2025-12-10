# PostgreSQL Database Backup & Restore Commands

⚠️ Important Disclaimers
  - This is only an example script only, adjust paths and commands as needed for your system.
  - This is for illustration purposes only and **not officially supported.**
  - Always test backup and restore procedures in a safe environment before relying on them in production.
  - The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.**

## Prerequisites

- Shell access to a machine with `kubectl` configured for the target Kubernetes cluster
- Access to the AIRM / Keycloak namespaces in the Kubernetes cluster
- Sufficient local disk space for database backups (database size + 20% recommended)

## What These Commands Do

**Backup Process:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for AIRM and Keycloak databases
3. Executes `pg_dump` inside each pod to create backups
4. Copies the backup files to your local machine
5. Cleans up temporary files from the containers
6. Creates timestamped backup file, e.g. `airm_db_backup_YYYY-MM-DD.sql`

**Restore Process:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for each database
3. Waits for pods to be ready
4. Pipes SQL backup files directly into the database containers
5. Restarts AIRM / Keycloak deployments to apply the restored data

## Database Backup - AIRM

```bash
# Set backup directory
# **change to preferred location if needed**
BACKUP_DIR="$HOME/db_backups"
mkdir -p "$BACKUP_DIR"
BACKUP_DATE=$(date +%Y-%m-%d)

# Get AIRM database credentials
# Retrieves the database username, password, and database name from Kubernetes secrets
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-user -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-user -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=airm

# Find primary AIRM pod
# Locates the primary PostgreSQL pod for AIRM (important for multi-replica setups)
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Backup AIRM database
# Step 1: Run pg_dump inside the container to create a SQL backup file
kubectl exec -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' pg_dump -U '$AIRM_USER' -d '$AIRM_DB' > /var/lib/postgresql/data/airm_backup.sql"

# Step 2: Copy the backup file from the container to your local machine
# **warning:** will overwrite existing file if done on same day, so append unique suffix if needed
kubectl cp -n airm "$AIRM_POD":/var/lib/postgresql/data/airm_backup.sql "$BACKUP_DIR/airm_db_backup_$BACKUP_DATE.sql"

# Step 3: Remove the temporary file from the container to free up space
kubectl exec -n airm "$AIRM_POD" -- rm /var/lib/postgresql/data/airm_backup.sql
```

## Database Backup - KEYCLOAK

```bash
# Set backup directory
# **change to preferred location if needed**
BACKUP_DIR="$HOME/db_backups"
mkdir -p "$BACKUP_DIR"
BACKUP_DATE=$(date +%Y-%m-%d)

# Get Keycloak database credentials
# Retrieves the database username, password, and database name from Kubernetes secrets
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-user -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-user -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=keycloak

# Find primary Keycloak pod
# Locates the primary PostgreSQL pod for Keycloak (important for multi-replica setups)
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Backup Keycloak database
# Step 1: Run pg_dump inside the container to create a SQL backup file
kubectl exec -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' pg_dump -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' > /var/lib/postgresql/data/keycloak_backup.sql"

# Step 2: Copy the backup file from the container to your local machine
# **warning:** will overwrite existing file if done on same day, so append unique suffix if needed
kubectl cp -n keycloak "$KEYCLOAK_POD":/var/lib/postgresql/data/keycloak_backup.sql "$BACKUP_DIR/keycloak_db_backup_$BACKUP_DATE.sql"

# Step 3: Remove the temporary file from the container to free up space
kubectl exec -n keycloak "$KEYCLOAK_POD" -- rm /var/lib/postgresql/data/keycloak_backup.sql

# Display completed backups
echo "Backups completed:"
ls -lh "$BACKUP_DIR"/*_$BACKUP_DATE.sql
```

## Database Restore - AIRM

```bash
# In the event of having an exisitng cluster, you can delete the existing CNPG cluster to ensure a clean restore 
# ArgoCD will recreate the CNPG clusters from scratch based on the GitOps configuration
kubectl delete cluster airm-cnpg -n airm` # **warning**: backup first if possible rollback is needed

# Set paths to your backup files
# Update the filename suffix to match your backup file
AIRM_BACKUP="$HOME/db_backups/airm_db_backup_DATE.sql"


# Get AIRM database credentials
# Retrieves the current database credentials from Kubernetes secrets
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-user -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-user -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=$(kubectl get secret -n airm airm-cnpg-user -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary AIRM pod
# Locates the primary PostgreSQL pod for AIRM
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Wait (up to 5 minutes) for pods to be ready, skip this step if not spinning up a new cluster
kubectl wait --for=condition=ready pod -n airm "$AIRM_POD" --timeout=300s

# Restore AIRM database
# Pipes the SQL backup file directly into psql running in the container
# This will overwrite existing data in the database
cat "$AIRM_BACKUP" | kubectl exec -i -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' psql -U '$AIRM_USER' -d '$AIRM_DB' -h localhost"

# Restart AIRM deployments to pick up restored data
# Forces all AIRM pods to restart and reload the restored database state
kubectl rollout restart deployment airm-api -n airm
```

## Database Restore - KEYCLOAK

```bash
# In the event of having an exisitng cluster, you can delete the existing CNPG cluster to ensure a clean restore 
# ArgoCD will recreate the CNPG clusters from scratch based on the GitOps configuration
kubectl delete cluster airm-cnpg -n airm` # **warning**: backup first if possible rollback is needed
# Set paths to your backup files
# Update the filename suffix to match your backup file
KEYCLOAK_BACKUP="$HOME/db_backups/keycloak_db_backup_DATE.sql"

# Get Keycloak database credentials
# Retrieves the current database credentials from Kubernetes secrets
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-user -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-user -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=$(kubectl get secret -n keycloak keycloak-cnpg-user -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary Keycloak pod
# Locates the primary PostgreSQL pod for Keycloak
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Wait (up to 5 minutes) for pods to be ready, skip this step if not spinning up a new cluster
kubectl wait --for=condition=ready pod -n keycloak "$KEYCLOAK_POD" --timeout=300s

# Restore Keycloak database
# Pipes the SQL backup file directly into psql running in the container
# This will overwrite existing data in the database
cat "$KEYCLOAK_BACKUP" | kubectl exec -i -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' psql -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' -h localhost"

# Restart AIRM deployments to pick up restored data
# Forces all AIRM pods to restart and reload the restored database state
kubectl rollout restart deployment keycloak -n keycloak
```
