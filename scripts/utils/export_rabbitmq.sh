#!/bin/bash
set -e

# default to exporting definitions only, unless --with-messages is provided
WITH_MESSAGES=false
if [[ "$1" == "--with-messages" ]]; then
    WITH_MESSAGES=true
fi

export_definitions() {
    # Export RabbitMQ definitions to a JSON file
    rabbitmqctl export_definitions $HOME/rmq_definitions.json
}

export_definitions_and_queue_messages() {
  # Stop RabbitMQ
  sudo systemctl stop rabbitmq-server
  
  # Create a backup of the RabbitMQ data directory
  sudo tar -cvf $HOME/rabbitmq-backup.tar /var/lib/rabbitmq/mnesia
  
  # Start RabbitMQ (or skip if immediately proceeding to restore):
  sudo systemctl start rabbitmq-server
  }

# Main script execution
if [ "$WITH_MESSAGES" = true ]; then
    export_definitions_and_queue_messages
    echo "RabbitMQ definitions and queued messages have been exported."
    echo "Definitions file: $HOME/rmq_definitions.json"
    echo "Data directory backup: $HOME/rabbitmq-backup.tar"
else
    export_definitions
    echo "RabbitMQ definitions have been exported."
    echo "Definitions file: $HOME/rmq_definitions.json"
fi