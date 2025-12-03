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

### Overview

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

### Detailed Command Example

For a backup & restore example (not officially supported), see: [`backup_restore_postgres.md`](backup_restore_postgres.md)

## 2. RabbitMQ Backup & Restore

RabbitMQ definitions (exchanges, queues, bindings, policies) can be exported and restored. Since messages in RabbitMQ are typically transient and processed within seconds, the backup focuses on configuration rather than message content.

### Overview

**Backup Process:**
1. Opens a shell in the RabbitMQ container
2. Uses `rabbitmqctl` to export all definitions to a JSON file
3. Copies the JSON file from the container to your local machine
4. Optionally saves a timestamped copy to network storage

**Restore Process:**
1. Copies the backup JSON file from your local machine to the RabbitMQ container
2. Opens a shell in the RabbitMQ container
3. Uses `rabbitmqctl` to import all definitions from the backup file
4. RabbitMQ configuration is restored (exchanges, queues, bindings, policies)

### Detailed Commands

For a backup & restore example (not officially supported), see: [`backup_restore_rabbitmq.md`](backup_restore_rabbitmq.md)

---

## 3. MinIO Backup & Restore

### Overview

MinIO supports two backup strategies:

#### Two-Way Replication (Bucket Replication)
**Note:** Bucket replication and site replication are mutually exclusive.

1. Sets up aliases for source and destination MinIO endpoints
2. Enables versioning on both buckets (required for replication)
3. Creates bidirectional replication rules
4. Provides a command to resync from backup when source fails

**Benefits:** Continuous, automatic backup with minimal data loss

#### One-Time Backup to Filesystem
1. Mounts an NFS share (or uses local filesystem)
2. Creates a timestamped backup directory
3. Uses `mc mirror` to copy all bucket contents to the backup location
4. Provides verification commands to compare file counts
5. Provides restore commands to mirror files back to MinIO

**Benefits:** Point-in-time snapshots stored on separate storage

### Detailed Commands

For a backup & restore example (not officially supported), see:: [`backup_restore_minio.md`](backup_restore_minio.md)
