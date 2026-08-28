#!/usr/bin/env bash
# Probe and heal the envoy-ai-gateway pod mutating webhook.
#
# Mainline cluster-forge enables cert-manager for webhook certs (root/values.yaml).
# This script covers legacy genCA clusters and post-cutover drift: the webhook uses
# failurePolicy: Fail and only matches pods labeled app.kubernetes.io/managed-by=envoy-gateway.
# When clientConfig.caBundle drifts from the controller TLS secret, Envoy HTTPS
# data-plane pods cannot be created.
set -euo pipefail

usage() {
  cat <<'EOF'
Probe and heal the envoy-ai-gateway pod mutating webhook.

Usage:
  ai-gateway-webhook-health.sh [--probe-only]

Exit 0 when the webhook accepts probe pod CREATE (dry-run/server) and, after a
heal, when https and ai-gateway Gateway resources report Programmed=True.
With --probe-only, fail without healing (for platform gate / CI checks).
Healing syncs caBundle, restarts the controller, rolls both https and ai-gateway
Envoy data-plane Deployments, then verifies gateway Programmed status.

Environment (defaults match the envoy-ai-gateway chart):
  WEBHOOK_NAME
  SECRET_NAMESPACE
  SECRET_NAME
  CONTROLLER_NAMESPACE
  CONTROLLER_DEPLOYMENT
  GATEWAY_NAMESPACE
  APPS_GATEWAY_NAME
  AI_GATEWAY_NAME
EOF
}

WEBHOOK_NAME="${WEBHOOK_NAME:-envoy-ai-gateway-gateway-pod-mutator.envoy-ai-gateway-system}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-envoy-ai-gateway-system}"
SECRET_NAME="${SECRET_NAME:-self-signed-cert-for-mutating-webhook}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-envoy-ai-gateway-system}"
CONTROLLER_DEPLOYMENT="${CONTROLLER_DEPLOYMENT:-ai-gateway-controller}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-envoy-gateway-system}"
APPS_GATEWAY_NAME="${APPS_GATEWAY_NAME:-https}"
AI_GATEWAY_NAME="${AI_GATEWAY_NAME:-ai-gateway}"
PROBE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-only)
      PROBE_ONLY=1
      shift
      ;;
    --heal-envoy-data-plane)
      # Backward compat: heal always restarts Envoy data planes now.
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

probe_ai_gateway_webhook() {
  kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<PROBE
apiVersion: v1
kind: Pod
metadata:
  name: ai-gateway-webhook-probe
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: envoy-gateway
spec:
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "1"]
PROBE
}

sync_webhook_ca_from_secret() {
  local secret_ca webhook_ca
  secret_ca="$(kubectl get secret "${SECRET_NAME}" -n "${SECRET_NAMESPACE}" -o jsonpath='{.data.ca\.crt}')"
  if [[ -z "${secret_ca}" ]]; then
    echo "secret ${SECRET_NAMESPACE}/${SECRET_NAME} missing ca.crt" >&2
    return 1
  fi
  webhook_ca="$(kubectl get mutatingwebhookconfigurations "${WEBHOOK_NAME}" -o jsonpath='{.webhooks[0].clientConfig.caBundle}')"
  if [[ "${secret_ca}" == "${webhook_ca}" ]]; then
    return 0
  fi
  echo "syncing webhook caBundle from ${SECRET_NAMESPACE}/${SECRET_NAME}"
  # RFC 6902 "add" inserts or replaces an object member, so this works when
  # caBundle is missing (cert-manager inject path) or present but stale.
  kubectl patch mutatingwebhookconfigurations "${WEBHOOK_NAME}" --type=json \
    --patch="[{\"op\":\"add\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"${secret_ca}\"}]"
}

restart_ai_gateway_controller() {
  kubectl rollout restart "deployment/${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" >/dev/null
  kubectl rollout status "deployment/${CONTROLLER_DEPLOYMENT}" -n "${CONTROLLER_NAMESPACE}" --timeout=180s
}

restart_envoy_data_plane() {
  local deployments
  deployments="$(kubectl get deployment -n "${GATEWAY_NAMESPACE}" \
    -l 'gateway.envoyproxy.io/owning-gateway-name in (https,ai-gateway)' \
    -o name 2>/dev/null || true)"
  if [[ -z "${deployments}" ]]; then
    echo "no envoy gateway data-plane deployments to restart" >&2
    return 0
  fi
  kubectl rollout restart deployment \
    -l 'gateway.envoyproxy.io/owning-gateway-name in (https,ai-gateway)' \
    -n "${GATEWAY_NAMESPACE}" >/dev/null
  kubectl rollout status deployment \
    -l 'gateway.envoyproxy.io/owning-gateway-name in (https,ai-gateway)' \
    -n "${GATEWAY_NAMESPACE}" --timeout=180s
}

verify_gateways_programmed() {
  local name programmed
  for name in "${APPS_GATEWAY_NAME}" "${AI_GATEWAY_NAME}"; do
    if ! kubectl get gateway "${name}" -n "${GATEWAY_NAMESPACE}" >/dev/null 2>&1; then
      continue
    fi
    if ! kubectl wait --for=condition=Programmed gateway/"${name}" \
      -n "${GATEWAY_NAMESPACE}" --timeout=180s; then
      echo "gateway ${GATEWAY_NAMESPACE}/${name} not Programmed after heal" >&2
      kubectl describe gateway "${name}" -n "${GATEWAY_NAMESPACE}" >&2 || true
      return 1
    fi
    programmed="$(kubectl get gateway "${name}" -n "${GATEWAY_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
    if [[ "${programmed}" != "True" ]]; then
      echo "gateway ${GATEWAY_NAMESPACE}/${name} Programmed=${programmed}" >&2
      kubectl describe gateway "${name}" -n "${GATEWAY_NAMESPACE}" >&2 || true
      return 1
    fi
    echo "gateway ${GATEWAY_NAMESPACE}/${name} Programmed=True"
  done
}

heal_ai_gateway_webhook() {
  sync_webhook_ca_from_secret || true
  restart_ai_gateway_controller
  restart_envoy_data_plane
}

if probe_ai_gateway_webhook; then
  echo "Pod-mutating webhook healthy"
  exit 0
fi

if [[ "${PROBE_ONLY}" -eq 1 ]]; then
  echo "Pod-mutating webhook is rejecting pods (probe-only; not healing)" >&2
  exit 1
fi

echo "Pod-mutating webhook is rejecting pods; healing"
heal_ai_gateway_webhook

if probe_ai_gateway_webhook; then
  if verify_gateways_programmed; then
    echo "Webhook and Envoy gateways healthy after heal"
    exit 0
  fi
  echo "Webhook accepts pods but Envoy gateway(s) not Programmed after heal" >&2
  exit 1
fi

echo "Webhook still rejecting pods — Envoy data plane cannot be recreated until this is fixed" >&2
exit 1
