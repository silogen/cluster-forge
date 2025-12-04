# AMD Enterprise AI Suite - Backup and Restore Procedures

This document covers backup and restore procedures for:
  1. Database Backup & Restore (AIRM & Keycloak)
  2. RabbitMQ Backup & Restore
  3. MinIO Backup & Restore (Bucket replication and one-off filesystem backup)

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
