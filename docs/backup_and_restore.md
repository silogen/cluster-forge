# AMD Enterprise AI Suite - Backup and Restore Procedures

This document covers backup and restore procedures for:
  1. Database Backup & Restore (AIRM & Keycloak)
  2. RabbitMQ Backup & Restore
  3. MinIO Backup & Restore (Bucket replication)

## Prerequisites

  - shell access to a machine with `kubectl` configured for the target Kubernetes cluster
  - Access to the AIRM and KEYCLOAK namespaces in the Kubernetes cluster
  - Note: the backup scripts use the PostgreSQL tools already available inside the CNPG database pods.

## 1. Database Backup & Restore

AIRM and Keycloak use Cloud Native PostgreSQL (CNPG) for data persistence. Use the provided script for backup and restore operations.

### Database Backup

#### Using the Export Script

The [`export_databases.sh`](../scripts/utils/export_databases.sh) script automates the backup process:

```bash
# Export to default location ($HOME)
./scripts/utils/export_databases.sh

# Export to custom directory (directory must exist)
mkdir -p /path/to/backup/directory
./scripts/utils/export_databases.sh /path/to/backup/directory
```

**What the script does:**
1. Retrieves database credentials from Kubernetes secrets
2. Finds the CNPG pods for AIRM and Keycloak databases
3. Executes `pg_dump` inside each pod to create backups in `/var/lib/postgresql/data/`
4. Copies the backup files to your local machine via `kubectl cp`
5. Cleans up temporary files from the containers
6. Creates timestamped backup files:
   - `airm_db_backup_YYYY-MM-DD.sql`
   - `keycloak_db_backup_YYYY-MM-DD.sql`

**Key Features:**
- No Docker or local PostgreSQL installation required
- Uses the exact PostgreSQL version from the database pods
- Automatic credential retrieval and cleanup

### Database Restore

#### Using the Import Script

The [`import_databases.sh`](../scripts/utils/import_databases.sh) script automates the restore process:

```bash
# Restore both databases
./scripts/utils/import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql

# Skip AIRM, restore only Keycloak
./scripts/utils/import_databases.sh skip /path/to/keycloak_backup.sql
```

**What the script does:**
- Retrieves current database credentials from Kubernetes secrets
- Waits for CNPG pods to be ready (up to 600 seconds)
- Establishes port-forward connections to the database pods
- Restores databases using `psql`
- Verifies pod status after restoration

**After restoration:**
- Restart AIRM API & UI pods to ensure they pick up the restored data:
  ```bash
  kubectl rollout restart deployment -n airm
  ```

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

## Script Locations

All backup and restore scripts are located in `scripts/utils/`:

- [`export_databases.sh`](../scripts/utils/export_databases.sh) - Export AIRM and Keycloak databases
- [`import_databases.sh`](../scripts/utils/import_databases.sh) - Import AIRM and Keycloak databases

## 3. MinIO Backup & Restore (Bucket replication)
### 1. Setup Two-Way Replication

From a local machine
1. Configure MinIO Aliases
```
# Set up source and destination MinIO endpoints
mc alias set source https://SOURCE_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY
mc alias set dest https://DEST_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY

ex) mc alias set dest https://minio.<mydomain>/ myuser mypsword
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

### 2. MinIO One-Time Backup to NFS Filesystem
Create mount point
```
sudo mkdir -p /mnt/minio-backup
```

Mount NFS share
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
ex) mc alias set source https://minio.<mydomain>/ myuser mypsword

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