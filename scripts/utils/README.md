# Backup and Restore Utilities

## ⚠️ Important Disclaimer

**The backup and restore process is not currently guaranteed to be backwards compatible between two arbitrary versions.** Please ensure that you are using compatible versions when performing backup and restore operations.

## Documentation

For comprehensive documentation on backup and restore procedures, please refer to:

[cluster-forge/docs/backup_and_restore.md](../../docs/backup_and_restore.md)

## Scripts

This directory contains utility scripts for backup and restore operations:

- `export_databases.sh` - Export database backups
- `export_rabbitmq.sh` - Export RabbitMQ configuration and data
- `import_databases.sh` - Import database backups
- `import_rabbitmq.sh` - Import RabbitMQ configuration and data
- `mirror_minio.sh` - Mirror MinIO storage
