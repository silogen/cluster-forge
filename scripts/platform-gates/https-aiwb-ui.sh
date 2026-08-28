#!/usr/bin/env bash
# HTTPS smoke: AI Workbench UI via the apps Envoy Gateway.
#
# Uses the gateway LoadBalancer IP with curl --resolve so the check works from
# the cluster head (Kaytoo/int-test) where hairpin NAT to the public VIP often fails.
set -euo pipefail

DOMAIN="${PLATFORM_DOMAIN:?PLATFORM_DOMAIN is required}"
HOST="aiwbui.${DOMAIN}"
URL="https://${HOST}/"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-envoy-gateway-system}"
APPS_GATEWAY="${APPS_GATEWAY_NAME:-https}"
CURL_TIMEOUT="${PLATFORM_GATES_CURL_TIMEOUT:-30}"

lb_ip="$(kubectl get gateway "${APPS_GATEWAY}" -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.status.addresses[?(@.type=="IPAddress")].value}' 2>/dev/null | head -1)"

if [[ -z "${lb_ip}" ]]; then
  lb_ip="$(kubectl get svc -n "${GATEWAY_NAMESPACE}" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${APPS_GATEWAY}" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi

if [[ -n "${lb_ip}" ]]; then
  echo "GET ${URL} via gateway LB ${lb_ip} (--resolve)"
  curl -sfI --max-time "${CURL_TIMEOUT}" \
    --resolve "${HOST}:443:${lb_ip}" \
    "${URL}"
else
  echo "GET ${URL} (direct; gateway LB IP not found in status)"
  curl -sfI --max-time "${CURL_TIMEOUT}" "${URL}"
fi

echo "HTTPS ${URL} OK"
