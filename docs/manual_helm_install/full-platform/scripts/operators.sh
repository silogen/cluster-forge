#!/usr/bin/env bash
# cert-manager v1.18.2, external-secrets 0.15.1, envoy-gateway v1.8.1,
# opentelemetry-operator 0.93.1, aim-engine-crds 0.2.6.
# AIM CRDs are applied with helm template; the chart is larger than Helm's 1MiB release Secret.
#
# The envoy-gateway chart runs a pre-install certgen Job. On a cold or a busy
# cluster that Job cannot reach the API service address and it fails. The chart
# gives no value to disable it, it sets backoffLimit 1, and it deletes the Job
# 30 seconds later. This script therefore installs envoy-gateway LAST and
# retries it, so one transient failure does not stop the other operators.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENVOY_GATEWAY_ATTEMPTS="${ENVOY_GATEWAY_ATTEMPTS:-4}"

helm repo add --force-update external-secrets https://charts.external-secrets.io
helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update external-secrets open-telemetry

helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.18.2 \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set crds.keep=false \
  --wait --timeout 6m

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 0.15.1 \
  --namespace external-secrets --create-namespace \
  --wait --timeout 6m

helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --version 0.93.1 \
  --namespace opentelemetry-operator-system --create-namespace \
  --wait --timeout 6m

helm_manifest aim-engine-crds \
  "${OCI}/aim-engine-crds-chart" \
  --version 0.2.6 \
  | kubectl apply --server-side --force-conflicts --filename -

install_envoy_gateway() {
  local attempt
  for attempt in $(seq 1 "${ENVOY_GATEWAY_ATTEMPTS}"); do
    echo "envoy-gateway: attempt ${attempt} of ${ENVOY_GATEWAY_ATTEMPTS}"
    if helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
        --version v1.8.1 \
        --namespace envoy-gateway-system --create-namespace \
        --wait --timeout 6m; then
      return 0
    fi
    # A failed pre-install hook leaves a release in the failed state. Remove it,
    # or the next attempt reports that the release has no deployed revision.
    helm uninstall envoy-gateway --namespace envoy-gateway-system --ignore-not-found || true
    sleep 20
  done
  echo "envoy-gateway did not install in ${ENVOY_GATEWAY_ATTEMPTS} attempts" >&2
  return 1
}

install_envoy_gateway
