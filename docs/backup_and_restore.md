# AMD Enterprise AI Suite - Backup and Restore Procedures

This document covers backup and restore procedures for:
  1. Database Backup & Restore (AIRM & Keycloak)
  2. RabbitMQ Backup & Restore
  3. MinIO Backup & Restore (Bucket replication)

## Prerequisites

  - shell access to a machine with `kubectl` configured for the target Kubernetes cluster
  - Access to the AIRM and KEYCLOAK namespaces in the Kubernetes cluster
  - Note: the backup scripts use the PostgreSQL tools already available inside the CNPG database pods.

## Preparation:

  - Inform users about the planned backup/restore operation, as services will be temporarily unavailable.
  - Cordon off the nodes hosting the database pods to prevent scheduling new pods during the operation:
    ```bash
    # Identify nodes hosting the CNPG pods
    kubectl get pods -n airm -o wide | grep cnpg
    kubectl get pods -n keycloak -o wide | grep cnpg

    # Cordon the identified nodes
    kubectl cordon <node-name-1>
    kubectl cordon <node-name-2>
    ```



## 1. CNPG (CloudNative Postgres)  Backup & Restore

AIRM and Keycloak use Cloud Native PostgreSQL (CNPG) for data persistence.

### Database Backup

**Note:** This is an example process specific to Ubuntu/Linux environments. Adjust paths and commands as needed for your system.

```bash
# Set backup directory
BACKUP_DIR="$HOME/db_backups"
mkdir -p "$BACKUP_DIR"
BACKUP_DATE=$(date +%Y-%m-%d)

# Get AIRM database credentials
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Get Keycloak database credentials
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary AIRM pod
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Find primary Keycloak pod
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Backup AIRM database
kubectl exec -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' pg_dump -U '$AIRM_USER' -d '$AIRM_DB' > /var/lib/postgresql/data/airm_backup.sql"
kubectl cp -n airm "$AIRM_POD":/var/lib/postgresql/data/airm_backup.sql "$BACKUP_DIR/airm_db_backup_$BACKUP_DATE.sql"
kubectl exec -n airm "$AIRM_POD" -- rm /var/lib/postgresql/data/airm_backup.sql

# Backup Keycloak database
kubectl exec -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' pg_dump -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' > /var/lib/postgresql/data/keycloak_backup.sql"
kubectl cp -n keycloak "$KEYCLOAK_POD":/var/lib/postgresql/data/keycloak_backup.sql "$BACKUP_DIR/keycloak_db_backup_$BACKUP_DATE.sql"
kubectl exec -n keycloak "$KEYCLOAK_POD" -- rm /var/lib/postgresql/data/keycloak_backup.sql

echo "Backups completed:"
ls -lh "$BACKUP_DIR"/*_$BACKUP_DATE.sql
```

**What this does:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for AIRM and Keycloak databases
3. Executes `pg_dump` inside each pod to create backups
4. Copies the backup files to your local machine
5. Cleans up temporary files from the containers
6. Creates timestamped backup files: `airm_db_backup_YYYY-MM-DD.sql` and `keycloak_db_backup_YYYY-MM-DD.sql`

### Database Restore

**Note:** This is an example process specific to Ubuntu/Linux environments. Adjust paths and commands as needed for your system.

```bash
# Set paths to your backup files
AIRM_BACKUP="$HOME/db_backups/airm_db_backup_2025-12-03.sql"
KEYCLOAK_BACKUP="$HOME/db_backups/keycloak_db_backup_2025-12-03.sql"

# Get AIRM database credentials
AIRM_USER=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
AIRM_PASSWORD=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
AIRM_DB=$(kubectl get secret -n airm airm-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Get Keycloak database credentials
KEYCLOAK_USER=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.username}' | base64 -d)
KEYCLOAK_PASSWORD=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_DB=$(kubectl get secret -n keycloak keycloak-cnpg-app -o jsonpath='{.data.dbname}' | base64 -d)

# Find primary AIRM pod
AIRM_POD=$(kubectl get pod -n airm -l cnpg.io/cluster=airm-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Find primary Keycloak pod
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -n airm "$AIRM_POD" --timeout=300s
kubectl wait --for=condition=ready pod -n keycloak "$KEYCLOAK_POD" --timeout=300s

# Restore AIRM database
cat "$AIRM_BACKUP" | kubectl exec -i -n airm "$AIRM_POD" -- bash -c "PGPASSWORD='$AIRM_PASSWORD' psql -U '$AIRM_USER' -d '$AIRM_DB' -h localhost"

# Restore Keycloak database
cat "$KEYCLOAK_BACKUP" | kubectl exec -i -n keycloak "$KEYCLOAK_POD" -- bash -c "PGPASSWORD='$KEYCLOAK_PASSWORD' psql -U '$KEYCLOAK_USER' -d '$KEYCLOAK_DB' -h localhost"

# Restart AIRM deployments to pick up restored data
kubectl rollout restart deployment -n airm

echo "Database restore completed"
```

**What this does:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the primary CNPG pod for each database
3. Waits for pods to be ready
4. Pipes SQL backup files directly into the database containers
5. Restarts AIRM deployments to apply the restored data

## 2. RabbitMQ Backup & Restore

RabbitMQ definitions (exchanges, queues, bindings, policies) can be exported and restored. Since messages in RabbitMQ are typically transient and processed within seconds, the backup focuses on configuration rather than message content.

### RabbitMQ Backup

**Step 1: Open a shell in the RabbitMQ container**
```bash
kubectl exec -it pod/airm-rabbitmq-server-0 --container='rabbitmq' -n airm -- sh
```

**Step 2: Export definitions inside the container**
```bash
rabbitmqctl export_definitions /tmp/rmq_defs.json
```

**Step 3: Exit the container shell (Ctrl+D or type `exit`)**

**Step 4: Copy the exported file to your local machine**
```bash
kubectl cp airm/airm-rabbitmq-server-0:/tmp/rmq_defs.json --container='rabbitmq' $HOME/rmq_export.json
```

**Step 5: (Optional) Copy to network storage**
```bash
# Copy to NFS drive or other backup location
cp $HOME/rmq_export.json /path/to/nfs/rmq_export_$(date +%Y-%m-%d).json
```

### RabbitMQ Restore

**Step 1: Copy the definitions file to the RabbitMQ container**
```bash
kubectl cp $HOME/rmq_export.json airm/airm-rabbitmq-server-0:/tmp/rmq_restore.json --container='rabbitmq'
```

**Step 2: Open a shell in the RabbitMQ container**
```bash
kubectl exec -it pod/airm-rabbitmq-server-0 --container='rabbitmq' -n airm -- sh
```

**Step 3: Import definitions inside the container**
```bash
rabbitmqctl import_definitions /tmp/rmq_restore.json
```

**Step 4: Exit the container shell (Ctrl+D or type `exit`)**

---

## 3. MinIO Backup & Restore
### 1. Setup Two-Way Replication (Bucket replication)

- **note:** bucket replication and site replication are mutually exclusive, so only one method can be used at a time.

From a local machine
1. Configure MinIO Aliases
```
# Set up source and destination MinIO endpoints
mc alias set source https://SOURCE_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY
mc alias set dest https://DEST_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY

ex) mc alias set dest https://minio.\<mydomain\>/ myuser mypsword
```

2. Enable Versioning (Required for Replication)
```
# Enable versioning on both source and destination buckets
mc version enable source/SOURCE_BUCKET_NAME/
mc version enable dest/DEST_BUCKET_NAME/
```

3. Setup Replication Rule
```
# Create a replication: source → dest
mc replicate add source/SOURCE_BUCKET_NAME/ \
   --remote-bucket 'https://ACCESS_KEY:SECRET_KEY@DEST_MINIO_ENDPOINT/DEST_BUCKET_NAME' \
   --replicate "delete,delete-marker,existing-objects"

# Create a reverse replication: dest → source
mc replicate add dest/DEST_BUCKET_NAME/ \
   --remote-bucket 'https://ACCESS_KEY:SECRET_KEY@SOURCE_MINIO_ENDPOINT/SOURCE_BUCKET_NAME' \
   --replicate "delete,delete-marker,existing-objects"

ex) mc replicate add source/my-source-bucket/ \
   --remote-bucket 'https://myuser:mypsword@minio.example.com/my-dest-bucket' \
   --replicate "delete,delete-marker,existing-objects"
```

4. Restore when source is broken
```
mc replicate resync start dest/DEST_BUCKET_NAME/ --remote-bucket $(mc replicate status dest/DEST_BUCKET_NAME/ --json | jq -r '.remoteTargets[].arn')
ex) mc replicate resync start dest/my-dest-bucket/ --remote-bucket $(mc replicate status dest/my-dest-bucket/ --json | jq -r '.remoteTargets[].arn')
```

### 2. MinIO One-Time Backup to Filesystem (e.g. local or NFS)

- This example uses NFS, if using local filesystem, skip the mount steps.

Create mount point
```
sudo mkdir -p /mnt/minio-backup
```

```
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup
```

Create Backup
```
# Create backup directory with timestamp
mkdir -p /mnt/minio-backup/backup-$(date +%Y-%m-%d_%H-%M)

# Set up source MinIO endpoints
# Use "CONSOLE_ACCESS_KEY" in the default-user secret, which having enough permissions
mc alias set source https://SOURCE_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY
ex) mc alias set source https://minio.\<mydomain\>/ myuser mypsword

# Mirror bucket contents to NFS
mc mirror source/BUCKET_NAME/ /mnt/minio-backup/backup-$(date+%Y-%m-%d_%H-%M)/BUCKET_NAME/ --overwrite
ex) mc mirror source/default-bucket/ /mnt/minio-backup/backup-$(date+%Y-%m-%d_%H-%M)/default-bucket/ --overwrite 

# Unmount when done
sudo umount /mnt/minio-backup
```

Verify Backup
```
# Re-mount and check
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup
ls -la /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/

# Compare file counts
# Check original bucket
mc ls --recursive source/BUCKET_NAME/ | wc -l

# Check backup
find /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/ -type f | wc -l
```

Restore from NFS Backup
```
# Mount NFS share
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup

# List available backups
ls -la /mnt/minio-backup/

# Restore from specific backup date
mc mirror /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/ source/BUCKET_NAME/ --overwrite
ex) mc mirror /mnt/minio-backup/backup-2024-11-24_14-30/default-bucket/ source/default-bucket/ --overwrite

# Verify restoration
mc ls source/BUCKET_NAME/

# Unmount when done
sudo umount /mnt/minio-backup
```
