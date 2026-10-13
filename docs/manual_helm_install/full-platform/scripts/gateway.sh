#!/usr/bin/env bash
# GatewayClass envoy-gateway and Gateway https in envoy-gateway-system.
# Uses TLS_CERT and TLS_KEY when set. Otherwise writes deps/.tls.crt and deps/.tls.key for *.${DOMAIN}.
# Run deps/operators.sh first.
#
# Helm applies the crds/ directory of a chart before it runs a pre-install hook.
# A failed envoy-gateway install therefore leaves the Gateway API CRDs on the
# cluster but installs no controller. This script then created a Gateway that
# nothing reconciles, and it reported success. It now checks for the controller.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_envoy_gateway_controller() {
  if ! kubectl get deployment envoy-gateway --namespace envoy-gateway-system >/dev/null 2>&1; then
    echo "The envoy-gateway controller is absent. Run deps/operators.sh first." >&2
    echo "The Gateway API CRDs alone do not serve a Gateway." >&2
    return 1
  fi
  kubectl wait --for=condition=Available deployment/envoy-gateway \
    --namespace envoy-gateway-system --timeout=300s
}

require_envoy_gateway_controller

cert="${TLS_CERT:-}"
key="${TLS_KEY:-}"
if [[ -z "${cert}" || -z "${key}" ]]; then
  cert="${DEPS_DIR}/.tls.crt"
  key="${DEPS_DIR}/.tls.key"
  if [[ ! -f "${cert}" || ! -f "${key}" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${key}" -out "${cert}" -days 825 \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}"
  fi
fi

kubectl create secret tls cluster-tls \
  --namespace envoy-gateway-system \
  --cert="${cert}" --key="${key}" \
  --dry-run=client --output yaml | kubectl apply --filename -

kubectl apply --filename - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: https
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: https
      hostname: "*.${DOMAIN}"
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: cluster-tls
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl wait --for=condition=Programmed gateway/https \
  --namespace envoy-gateway-system --timeout=300s
