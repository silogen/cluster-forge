#!/usr/bin/env bash
# Assert Envoy Gateway resources report Programmed=True.
set -euo pipefail

GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-envoy-gateway-system}"
APPS_GATEWAY="${APPS_GATEWAY_NAME:-https}"
AI_GATEWAY="${AI_GATEWAY_NAME:-ai-gateway}"

check_gateway() {
  local name="$1"
  if ! kubectl get gateway "${name}" -n "${GATEWAY_NAMESPACE}" >/dev/null 2>&1; then
    echo "gateway ${GATEWAY_NAMESPACE}/${name} not found (skipped)"
    return 0
  fi
  kubectl wait --for=condition=Programmed gateway/"${name}" \
    -n "${GATEWAY_NAMESPACE}" --timeout=120s
  local programmed
  programmed="$(kubectl get gateway "${name}" -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
  if [[ "${programmed}" != "True" ]]; then
    echo "gateway ${GATEWAY_NAMESPACE}/${name} Programmed=${programmed}" >&2
    kubectl describe gateway "${name}" -n "${GATEWAY_NAMESPACE}" >&2 || true
    return 1
  fi
  echo "gateway ${GATEWAY_NAMESPACE}/${name} Programmed=True"
}

check_gateway "${APPS_GATEWAY}"
check_gateway "${AI_GATEWAY}"
