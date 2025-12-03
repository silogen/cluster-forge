# RabbitMQ Backup & Restore Commands

This document provides the step-by-step commands for backing up and restoring RabbitMQ definitions (exchanges, queues, bindings, policies).

**Note:** Since messages in RabbitMQ are typically transient and processed within seconds, this backup focuses on configuration rather than message content. This is an example process specific to Ubuntu/Linux environments. Adjust paths and commands as needed for your system.

## RabbitMQ Backup

### Step 1: Open a shell in the RabbitMQ container
```bash
# Opens an interactive shell session inside the RabbitMQ container
kubectl exec -it pod/airm-rabbitmq-server-0 --container='rabbitmq' -n airm -- sh
```

### Step 2: Export definitions inside the container
```bash
# Exports all RabbitMQ definitions (exchanges, queues, bindings, policies) to a JSON file
# This command is run inside the container shell from Step 1
rabbitmqctl export_definitions /tmp/rmq_defs.json
```

### Step 3: Exit the container shell
Exit the shell by pressing `Ctrl+D` or typing `exit`

### Step 4: Copy the exported file to your local machine
```bash
# Copies the definitions file from the container to your local home directory
kubectl cp airm/airm-rabbitmq-server-0:/tmp/rmq_defs.json --container='rabbitmq' $HOME/rmq_export.json
```

### Step 5: (Optional) Copy to network storage
```bash
# Saves the backup to a network location (e.g., NFS) with a timestamp
# Replace /path/to/nfs with your actual network storage path
cp $HOME/rmq_export.json /path/to/nfs/rmq_export_$(date +%Y-%m-%d).json
```

## RabbitMQ Restore

### Step 1: Copy the definitions file to the RabbitMQ container
```bash
# Copies your backup file from your local machine into the RabbitMQ container
# Update the filename if you're using a different backup file
kubectl cp $HOME/rmq_export.json airm/airm-rabbitmq-server-0:/tmp/rmq_restore.json --container='rabbitmq'
```

### Step 2: Open a shell in the RabbitMQ container
```bash
# Opens an interactive shell session inside the RabbitMQ container
kubectl exec -it pod/airm-rabbitmq-server-0 --container='rabbitmq' -n airm -- sh
```

### Step 3: Import definitions inside the container
```bash
# Imports all RabbitMQ definitions from the backup JSON file
# This command is run inside the container shell from Step 2
# This will overwrite existing RabbitMQ configuration
rabbitmqctl import_definitions /tmp/rmq_restore.json
```

### Step 4: Exit the container shell
Exit the shell by pressing `Ctrl+D` or typing `exit`

## What These Commands Do

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
