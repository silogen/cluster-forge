#!/usr/bin/env bash
# RabbitMQ cluster operator v2.15.0 and airm-rabbitmq chart.
# Skip this and set airm-api.airm.rabbitmq.host for your own broker.
# Requires the airm-rabbitmq-admin Secret from deps/secrets.sh or deps/external-secrets.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kubectl apply --server-side --force-conflicts \
  --filename https://github.com/rabbitmq/cluster-operator/releases/download/v2.15.0/cluster-operator.yml

helm upgrade --install airm-infra-rabbitmq \
  "${OCI}/airm-rabbitmq-chart" \
  --version "${CHART_VERSION}" \
  --namespace airm --create-namespace \
  --set persistence.storageClassName="${STORAGE_CLASS}" \
  --wait --timeout 10m
