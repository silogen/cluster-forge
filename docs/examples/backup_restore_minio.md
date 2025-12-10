# MinIO Backup & Restore Commands

This document provides the step-by-step commands for MinIO backup and restore operations.

⚠️ Important Disclaimers
  - This is only an example script only, adjust paths and commands as needed for your system.
  - This is for illustration purposes only and **not officially supported.**
  - Always test backup and restore procedures in a safe environment before relying on them in production.
  - The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.**


## Prerequisites

- Shell access to a machine with `kubectl` configured for the target Kubernetes cluster
- MinIO client (`mc`) installed on your local machine, **OR** access to run commands inside the `minio` pod in the MinIO tenant namespace
  - To install `mc` locally: [https://min.io/docs/minio/linux/reference/minio-mc.html](https://min.io/docs/minio/linux/reference/minio-mc.html)
  - To run inside the pod: `kubectl exec -it -n <minio-namespace> <minio-pod-name> -- sh`
- For NFS backups: Access to mount NFS shares (requires `sudo` privileges)
- For bucket replication: Access to both source and destination MinIO endpoints
- The `jq` command-line JSON processor (for replication resync commands)

## 1. Setup Two-Way Replication (Bucket replication)

**Important:** Bucket replication and site replication are mutually exclusive, so only one method can be used at a time.

These commands are run from a local machine with MinIO client (`mc`) installed.

### Step 1: Configure MinIO Aliases
```bash
# Set up source and destination MinIO endpoints
# Replace SOURCE_MINIO_ENDPOINT, DEST_MINIO_ENDPOINT, ACCESS_KEY, and SECRET_KEY with your values
mc alias set source https://SOURCE_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY
mc alias set dest https://DEST_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY

# Example:
# mc alias set dest https://minio.\<mydomain\>/ myuser mypassword
```

### Step 2: Enable Versioning (Required for Replication)
```bash
# Enable versioning on both source and destination buckets
# Versioning is required for replication to work properly
mc version enable source/SOURCE_BUCKET_NAME/
mc version enable dest/DEST_BUCKET_NAME/
```

### Step 3: Setup Replication Rule
```bash
# Create a replication from source to destination
# This will replicate all objects, including deletions
mc replicate add source/SOURCE_BUCKET_NAME/ \
   --remote-bucket 'https://ACCESS_KEY:SECRET_KEY@DEST_MINIO_ENDPOINT/DEST_BUCKET_NAME' \
   --replicate "delete,delete-marker,existing-objects"

# Create a reverse replication from destination to source
# This creates bidirectional replication
mc replicate add dest/DEST_BUCKET_NAME/ \
   --remote-bucket 'https://ACCESS_KEY:SECRET_KEY@SOURCE_MINIO_ENDPOINT/SOURCE_BUCKET_NAME' \
   --replicate "delete,delete-marker,existing-objects"

# Example:
# mc replicate add source/my-source-bucket/ \
#    --remote-bucket 'https://myuser:mypassword@minio.example.com/my-dest-bucket' \
#    --replicate "delete,delete-marker,existing-objects"
```

### Step 4: Restore when source is broken
```bash
# Forces a resync from destination to source when the source fails
# This retrieves the replication ARN automatically and initiates a full resync
mc replicate resync start dest/DEST_BUCKET_NAME/ --remote-bucket $(mc replicate status dest/DEST_BUCKET_NAME/ --json | jq -r '.remoteTargets[].arn')

# Example:
# mc replicate resync start dest/my-dest-bucket/ --remote-bucket $(mc replicate status dest/my-dest-bucket/ --json | jq -r '.remoteTargets[].arn')
```

## 2. MinIO One-Time Backup to Filesystem (e.g. local or NFS)

**Note:** This example uses NFS. If using local filesystem, skip the mount steps.

### Create mount point
```bash
# Creates the directory where NFS will be mounted
sudo mkdir -p /mnt/minio-backup
```

### Mount NFS share
```bash
# Mounts the NFS share to the local directory
# Replace NFS_SERVER and /path/to/minio/backup with your NFS server details
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup
```

### Create Backup
```bash
# Create backup directory with timestamp
# This creates a unique directory for this backup using current date and time
mkdir -p /mnt/minio-backup/backup-$(date +%Y-%m-%d_%H-%M)

# Set up source MinIO endpoints
# Use "CONSOLE_ACCESS_KEY" from the default-user secret (has required permissions)
mc alias set source https://SOURCE_MINIO_ENDPOINT/ ACCESS_KEY SECRET_KEY

# Example:
# mc alias set source https://minio.\<mydomain\>/ myuser mypassword

# Mirror bucket contents to NFS
# This copies all files from the MinIO bucket to the NFS backup location
mc mirror source/BUCKET_NAME/ /mnt/minio-backup/backup-$(date +%Y-%m-%d_%H-%M)/BUCKET_NAME/ --overwrite

# Example:
# mc mirror source/default-bucket/ /mnt/minio-backup/backup-$(date +%Y-%m-%d_%H-%M)/default-bucket/ --overwrite 

# Unmount when done
# Safely disconnects the NFS share
sudo umount /mnt/minio-backup
```

### Verify Backup
```bash
# Re-mount and check
# Reconnects to the NFS share to verify the backup
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup
ls -la /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/

# Compare file counts
# Verify the backup by comparing the number of files
# Check original bucket
mc ls --recursive source/BUCKET_NAME/ | wc -l

# Check backup
find /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/ -type f | wc -l
```

### Restore from NFS Backup
```bash
# Mount NFS share
# Connects to the NFS share containing backups
sudo mount -t nfs NFS_SERVER:/path/to/minio/backup /mnt/minio-backup

# List available backups
# Shows all backup directories to help you choose which one to restore
ls -la /mnt/minio-backup/

# Restore from specific backup date
# Mirrors files from the backup back to the MinIO bucket
# Replace YYYY-MM-DD_HH-MM with your actual backup directory name
mc mirror /mnt/minio-backup/backup-YYYY-MM-DD_HH-MM/BUCKET_NAME/ source/BUCKET_NAME/ --overwrite

# Example:
# mc mirror /mnt/minio-backup/backup-2024-11-24_14-30/default-bucket/ source/default-bucket/ --overwrite

# Verify restoration
# Lists files in the bucket to confirm restoration
mc ls source/BUCKET_NAME/

# Unmount when done
# Safely disconnects the NFS share
sudo umount /mnt/minio-backup
```

## What These Commands Do

**Two-Way Replication:**
1. Sets up aliases for source and destination MinIO endpoints
2. Enables versioning on both buckets (required for replication)
3. Creates bidirectional replication rules
4. Provides a command to resync from backup when source fails

**One-Time Backup:**
1. Mounts an NFS share (or uses local filesystem)
2. Creates a timestamped backup directory
3. Uses `mc mirror` to copy all bucket contents to the backup location
4. Provides verification commands to compare file counts
5. Provides restore commands to mirror files back to MinIO

**Benefits:**
- **Replication:** Continuous, automatic backup with minimal data loss
- **One-Time Backup:** Point-in-time snapshots stored on separate storage
