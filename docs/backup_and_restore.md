# AMD Enterprise AI Suite - Backup and Restore Procedures

This document covers backup and restore procedures for:
  1. [Database Backup & Restore (AIRM & Keycloak)](#1-cnpg-cloudnative-postgres-backup--restore)
  2. [RabbitMQ Backup & Restore](#2-rabbitmq-backup--restore)
  3. [MinIO Backup & Restore (Bucket replication and one-off filesystem backup)](#3-minio-backup--restore)
  4. [Longhorn Backup & Restore](#4-longhorn-backup--restore)

**Note:** Each detailed command file includes specific prerequisites for that backup type.

## Preparation:

  - Inform users about the planned backup/restore operation, as services will be temporarily unavailable.
  - Example: cordon (prevent scheduling) of nodes hosting the database pods:
    ```bash
    # Identify nodes hosting the CNPG pods and cordon them
    kubectl cordon $(kubectl get pods -n airm -o wide -l cnpg.io/cluster=airm-cnpg,cnpg.io/instanceRole=primary --no-headers | awk '{print $7}')
    kubectl cordon $(kubectl get pods -n keycloak -o wide -l cnpg.io/cluster=airm-cnpg,cnpg.io/instanceRole=primary --no-headers | awk '{print $7}')
    ```

## 1. CNPG (CloudNative Postgres)  Backup & Restore

AIRM and Keycloak use Cloud Native PostgreSQL (CNPG) for data persistence.

### Overview

**Backup Process:**
1. Retrieve database credentials from Kubernetes secrets
2. Find the primary CNPG pod for AIRM and Keycloak databases
3. Execute `pg_dump` inside each pod to create backups
4. Copy the backup files to your local machine
5. Clean up temporary files from the containers
6. Create timestamped backup files: `airm_db_backup_YYYY-MM-DD.sql` and `keycloak_db_backup_YYYY-MM-DD.sql`

**Restore Process:**
1. Retrieve database credentials from Kubernetes secrets
2. Find the primary CNPG pod for each database
3. Wait for pods to be ready
4. Pipe SQL backup files directly into the database containers
5. Restart AIRM deployments to apply the restored data

### Detailed Command Example

For a backup & restore example (not officially supported), see: [`backup_restore_postgres.md`](examples/backup_restore_postgres.md)

## 2. RabbitMQ Backup & Restore

RabbitMQ definitions (exchanges, queues, bindings, policies) can be exported and restored. Since messages in RabbitMQ are typically transient and processed within seconds, the backup focuses on configuration rather than message content.

### Overview

**Backup Process:**
1. Open a shell in the RabbitMQ container
2. Use `rabbitmqctl` to export all definitions to a JSON file
3. Copy the JSON file from the container to your local machine
4. Optionally save a timestamped copy to network storage

**Restore Process:**
1. Copy the backup JSON file from your local machine to the RabbitMQ container
2. Open a shell in the RabbitMQ container
3. Use `rabbitmqctl` to import all definitions from the backup file
4. Restore RabbitMQ configuration (exchanges, queues, bindings, policies)

### Detailed Commands

For a backup & restore example (not officially supported), see: [`backup_restore_rabbitmq.md`](examples/backup_restore_rabbitmq.md)

---

## 3. MinIO Backup & Restore

### Overview

MinIO supports two backup strategies:

#### Two-Way Replication (Bucket Replication)
**Note:** Bucket replication and site replication are mutually exclusive.

1. Set up aliases for source and destination MinIO endpoints
2. Enable versioning on both buckets (required for replication)
3. Create bidirectional replication rules
4. Provide a command to resync from backup when source fails

**Benefits:** Continuous, automatic backup with minimal data loss

#### One-Time Backup to Filesystem
1. Mount an NFS share (or use local filesystem)
2. Create a timestamped backup directory
3. Use `mc mirror` to copy all bucket contents to the backup location
4. Provide verification commands to compare file counts
5. Provide restore commands to mirror files back to MinIO

**Benefits:** Point-in-time snapshots stored on separate storage

### Detailed Commands

For a backup & restore example (not officially supported), see:: [`backup_restore_minio.md`](examples/backup_restore_minio.md)

---

## 4. Longhorn Backup & Restore

Longhorn provides block storage for Kubernetes workloads and supports snapshots and backups to external storage targets.

### Overview

**Backup Configuration:**
1. Configure a backup target (S3-compatible storage, NFS, or other supported backends)
2. Set up backup credentials if using S3
3. Configure backup settings in the Longhorn UI or via YAML

**Backup Process:**
1. Create snapshots of volumes
2. Back up snapshots to the configured backup target
3. Optionally configure recurring backup jobs for automated backups

**Restore Process:**
1. List available backups from the backup target
2. Restore volumes from backups
3. For StatefulSets, follow specific procedures to maintain pod identity
4. Restore recurring job configurations from backups

**Additional Operations:**
- Manually synchronize backup volumes when needed
- Restore volume recurring jobs from backup metadata

### Detailed Procedures

#### Setting a Backup Target
Configure where Longhorn will store backups. See: [Set Backup Target Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/set-backup-target/)

#### Create a Backup
Create on-demand or scheduled backups of your volumes. See: [Create a Backup Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/create-a-backup/)

#### Restore from a Backup
Restore volumes from previously created backups. See: [Restore from a Backup Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/restore-from-a-backup/)

#### Restore Volumes for Kubernetes StatefulSets
Special procedures for restoring StatefulSet volumes while maintaining pod identity. See: [Restore StatefulSet Volumes Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/restore-statefulset/)

#### Restore Volume Recurring Jobs from a Backup
Restore recurring backup job configurations from backup metadata. See: [Restore Recurring Jobs Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/restore-recurring-jobs-from-a-backup/)

#### Synchronize Backup Volumes Manually
Manually sync backup volumes when automatic synchronization is disabled or needs to be triggered. See: [Synchronize Backup Volumes Documentation](https://longhorn.io/docs/1.8.0/snapshots-and-backups/backup-and-restore/synchronize_backup_volumes_manually/)
