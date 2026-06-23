# Backup and Restore Utilities

⚠️ Important Disclaimers
  - This folder contains example scripts only, adjust paths and commands as needed for your system.
  - This is for illustration purposes only and **not officially supported.**
  - Always test backup and restore procedures in a safe environment before relying on them in production.
  - The backup and restore processes are **not guaranteed to be backwards compatible between two arbitrary versions.**

## Documentation

For comprehensive documentation on backup and restore procedures, please refer to:

[cluster-forge/docs/backup_and_restore.md](../../docs/backup_and_restore.md)

## Scripts

This directory contains utility scripts for backup and restore operations, as well as upgrade scripts. The scripts include:

- `export_databases.sh` - Export database backups
- `export_rabbitmq.sh` - Export RabbitMQ configuration and data
- `import_databases.sh` - Import database backups
- `import_rabbitmq.sh` - Import RabbitMQ configuration and data
- `mirror_minio.sh` - Mirror MinIO storage
- `upgrade_v2.sh` - Upgrade script for cluster-forge migration v1.8.0 to v2.0.x

## Upgrade Script
The `upgrade_v2.sh` script is designed to assist with the migration from cluster-forge v1.8.0 to v2.0.x (or 2.0.0-rcx release candidate). It performs the following tasks:
- pre-requiste: backup airm-cnpg and airm-rabbitmq using the export scripts
- disables auto-sync for the cluster-forge ArgoCD application
- does a background deletion of ArgoCD apps: aim-cluster-model-source, kaiwo, kaiwo-crds, kaiwo-config, and airm
- removes aimclustermodel, aimclustermodelsource, aimclustermodeltemplates
- removes secrets in AIRM namespace