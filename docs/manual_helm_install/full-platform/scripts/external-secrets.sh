#!/usr/bin/env bash
# airm-external-secrets and aiwb-external-secrets charts.
# Alternative to deps/secrets.sh. Requires ClusterSecretStore openbao-secret-store
# (deps/openbao.sh writes the keys). Also creates aiwb-openbao-token, which the chart does not sync.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

helm upgrade --install airm-infra-external-secrets \
  "${OCI}/airm-external-secrets-chart" \
  --version "${CHART_VERSION}" \
  --namespace airm --create-namespace

helm upgrade --install aiwb-infra-external-secrets \
  "${OCI}/aiwb-external-secrets-chart" \
  --version "${CHART_VERSION}" \
  --namespace aiwb --create-namespace

ksecret aiwb aiwb-openbao-token \
  --from-literal=value="${OPENBAO_TOKEN}"
