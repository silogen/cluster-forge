#!/bin/bash

set -euo pipefail

export RMQ_EXPORT_FILE="$1"

# exit if the file doesn't exist
if [ ! -f "$RMQ_EXPORT_FILE" ]; then
  echo "File $RMQ_EXPORT_FILE does not exist."
  exit 1
fi

kubectl cp "$RMQ_EXPORT_FILE" "airm/airm-infra-rabbitmq-rabbitmq-server-0:/tmp/export.json" --container=rabbitmq
kubectl exec -n airm "pod/airm-infra-rabbitmq-rabbitmq-server-0" --container=rabbitmq -- \
rabbitmqctl import_definitions "/tmp/export.json"