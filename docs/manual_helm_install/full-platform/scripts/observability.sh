#!/usr/bin/env bash
# Prometheus Operator CRDs 23.0.0 and the LGTM stack (cluster-forge otel-lgtm-stack/v1.0.8).
# The LGTM chart hardcodes storageClassName default and emits a Namespace, so this renders and applies it.
# Grafana reads Secret grafana-admin-credentials.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

forge="$(forge_dir)"

helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install prometheus-crds prometheus-community/prometheus-operator-crds \
  --version 23.0.0 \
  --namespace prometheus-system --create-namespace \
  --wait --timeout 6m

helm template otel-lgtm-stack "${forge}/sources/otel-lgtm-stack/v1.0.8" \
  --namespace otel-lgtm-stack \
  --set cluster.name="${DOMAIN}" \
  | sed "s|storageClassName: default|storageClassName: ${STORAGE_CLASS}|" \
  | kubectl apply --server-side --force-conflicts --filename -

ksecret otel-lgtm-stack grafana-admin-credentials \
  --from-literal=username=admin \
  --from-literal=password="${GRAFANA_ADMIN_PASSWORD}"
