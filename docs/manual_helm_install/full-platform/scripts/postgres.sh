#!/usr/bin/env bash
# CloudNativePG operator 0.26.0 and the AIRM and AIWB PostgreSQL charts.
# Skip this and set airm-api.airm.postgresql.host and postgresql.host for your own PostgreSQL 14+.
# AIWB_CNPG_INSTANCES defaults to the chart value 3. Set it to 1 on one node.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_cnpg_operator

helm upgrade --install airm-infra-cnpg \
  "${OCI}/airm-cnpg-chart" \
  --version "${CHART_VERSION}" \
  --namespace airm --create-namespace \
  --set storage.storageClass="${STORAGE_CLASS}" \
  --set walStorage.storageClass="${STORAGE_CLASS}" \
  --wait --timeout 10m

aiwb_args=()
if [[ -n "${AIWB_CNPG_INSTANCES:-}" ]]; then
  aiwb_args+=(--set "instances=${AIWB_CNPG_INSTANCES}")
fi

helm upgrade --install aiwb-infra-cnpg \
  "${OCI}/aiwb-cnpg-chart" \
  --version "${CHART_VERSION}" \
  --namespace aiwb --create-namespace \
  --set storage.storageClass="${STORAGE_CLASS}" \
  --set walStorage.storageClass="${STORAGE_CLASS}" \
  "${aiwb_args[@]}" \
  --wait --timeout 10m
