# Backup and Restore Utilities

⚠️ Important Disclaimers
  - This is only an example script only, adjust paths and commands as needed for your system.
  - This is for illustration purposes only and **not officially supported.**
  - Always test backup and restore procedures in a safe environment before relying on them in production.
  - The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.**

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
