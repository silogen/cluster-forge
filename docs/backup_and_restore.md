# AMD Enterprise AI Suite - Backup and Restore Procedures

This document covers backup and restore procedures for:
  1. Database Backup & Restore (AIRM & Keycloak)
  2. RabbitMQ Backup & Restore
  3. MinIO Backup & Restore (Bucket replication)

## Prerequisites

### Install PostgreSQL 17 Client Tools

If you don't have `pg_dump` and `psql` installed locally, use the provided installation script:

```bash
./scripts/utils/install_postgres_17.sh
```

This script will install PostgreSQL 17 client tools on your system (supports Debian/Ubuntu).

## 1. Database Backup & Restore

AIRM and Keycloak use Cloud Native PostgreSQL (CNPG) for data persistence. Use the provided scripts for backup and restore operations.

### Database Backup

#### Using the Export Script

The `export_databases.sh` script automates the backup process:

```bash
# Export to default location ($HOME)
./scripts/utils/export_databases.sh

# Export to custom directory (directory must exist)
mkdir -p /path/to/backup/directory
./scripts/utils/export_databases.sh /path/to/backup/directory
```

**What the script does:**
- Validates the output directory exists (exits with error if not found)
- Retrieves database credentials from Kubernetes secrets
- Creates timestamped backup files:
  - `airm_db_backup_YYYY-MM-DD.sql`
  - `keycloak_db_backup_YYYY-MM-DD.sql`
- Uses `pg_dump --clean` for complete schema and data backup, and preventing manual cleanup during restore (when initial schema exists)

#### Manual Backup Process

If you need to perform manual backups:

1. **Port Forward to CNPG Pods:**

   ```bash
   # AIRM database (port 5432):
   kubectl port-forward -n airm pod/$(kubectl get pods -n airm | grep -P "airm-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432

   # Keycloak database (port 5433 to avoid conflict):
   kubectl port-forward -n keycloak pod/$(kubectl get pods -n keycloak | grep -P "keycloak-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5433:5432
   ```

2. **Retrieve Credentials:**
   ```bash
   # AIRM credentials
   kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode
   kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode

   # Keycloak credentials
   kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode
   kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode
   ```

3. **Run Backup:**
   ```bash
   # AIRM backup
   pg_dump --clean -h 127.0.0.1 -U <airm_username> airm > airm_backup_$(date +%Y-%m-%d).sql

   # Keycloak backup (note port 5433)
   pg_dump --clean -h 127.0.0.1 -p 5433 -U <keycloak_username> keycloak > keycloak_backup_$(date +%Y-%m-%d).sql
   ```

### Database Restore

#### Using the Import Script

The `import_databases.sh` script automates the restore process:

```bash
# Restore both databases
./scripts/utils/import_databases.sh /path/to/airm_backup.sql /path/to/keycloak_backup.sql

# Skip AIRM, restore only Keycloak
./scripts/utils/import_databases.sh skip /path/to/keycloak_backup.sql
```

**What the script does:**
- Retrieves current database credentials from Kubernetes secrets
- Waits for CNPG pods to be ready (up to 600 seconds)
- Restores databases using `psql`
- Verifies pod status after restoration

**After restoration:**
- Restart AIRM API & UI pods to ensure they pick up the restored data:
  ```bash
  kubectl rollout restart deployment -n airm
  ```

#### Manual Restore Process

If you need to perform manual restore:

1. **Port Forward to CNPG Pods** (same as backup step 1)

2. **Run Restore:**
   ```bash
   # AIRM restore
   psql -h 127.0.0.1 -U <airm_username> airm < airm_backup_YYYY-MM-DD.sql

   # Keycloak restore (note port 5433)
   psql -h 127.0.0.1 -p 5433 -U <keycloak_username> keycloak < keycloak_backup_YYYY-MM-DD.sql
   ```

3. **Restart AIRM pods:**
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

- `install_postgres_17.sh` - Install PostgreSQL 17 client tools
- `export_databases.sh` - Export AIRM and Keycloak databases
- `import_databases.sh` - Import AIRM and Keycloak databases

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
