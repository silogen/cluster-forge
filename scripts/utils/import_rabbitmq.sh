#!/bin/bash
set -e

# Usage: ./import_rabbitmq.sh [--with-messages] [INPUT_JSON_FILE]

# Parse arguments
INPUT_DIR=$HOME
WITH_MESSAGES=false

for arg in "$@"; do
    if [[ "$arg" == "--with-messages" ]]; then
        WITH_MESSAGES=true
    elif [[ "$arg" != --* ]]; then
        INPUT_DIR=$arg
    fi
done

import_definitions() {
    rabbitmqctl import_definitions /path/to/backup_definitions.json
}

import_definitions_and_messages() {
    # Stop RabbitMQ:
    sudo systemctl stop rabbitmq-server

    # Remove default Mnesia directory:
    sudo rm -rf /var/lib/rabbitmq/mnesia 

    # Restore the RabbitMQ data directory from the backup:
    sudo tar -xvf rabbitmq-backup.tar -C /

    # Fix ownershiop of the restored files:
    sudo chown -R rabbitmq:rabbitmq /var/lib/rabbitmq

    # Start RabbitMQ:
    sudo systemctl start rabbitmq-server
}

# Main script execution
if [ "$WITH_MESSAGES" = true ]; then
    import_definitions_and_messages
    echo "RabbitMQ definitions and queued messages have been imported."
    echo "Definitions file: $INPUT_DIR/rmq_definitions.json"
else
    export_definitions
    echo "RabbitMQ definitions have been imported."
    echo "Definitions file: $INPUT_DIR/rmq_definitions.json"
fi