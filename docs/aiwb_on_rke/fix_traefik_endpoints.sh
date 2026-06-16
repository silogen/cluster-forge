#!/usr/bin/env bash
#
# Live fix for: HTTPRoutes return Traefik's "404 page not found".
#
# Cause: the routes do host routing via a Host-header RegularExpression match and
# (for AIWB) path RegularExpression matches. Traefik's Gateway API implementation
# does NOT support those match types — it marks the route Accepted but builds no
# working router, so every request 404s.
#
# Fix per route: set spec.hostnames (the supported way to route by host) and replace
# each rule's matches with a plain "PathPrefix: /" (dropping the unsupported header
# and regex-path matches). Existing backendRefs/timeouts are preserved.
#
# Run on the cluster (root kubeconfig):  sudo bash fix_traefik_endpoints.sh <DOMAIN>
set -euo pipefail

# Require DOMAIN as the first argument (no default).
if [ -z "${1:-}" ]; then
  echo "❌ Error: DOMAIN parameter is required" >&2
  echo "" >&2
  echo "Usage: $0 <DOMAIN>" >&2
  echo "Example: $0 aiwb-test.silogen.ai" >&2
  exit 1
fi
DOMAIN="$1"
PP='[{"path":{"type":"PathPrefix","value":"/"}}]'   # the only match we keep

echo "🔧 aiwb-ui-route (host aiwbui, 1 rule)"
kubectl patch httproute aiwb-ui-route -n aiwb --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"aiwbui.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}}
]"

echo "🔧 aiwb-api-route (host aiwbapi, 3 rules)"
kubectl patch httproute aiwb-api-route -n aiwb --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"aiwbapi.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}},
  {\"op\":\"replace\",\"path\":\"/spec/rules/1/matches\",\"value\":${PP}},
  {\"op\":\"replace\",\"path\":\"/spec/rules/2/matches\",\"value\":${PP}}
]"

echo "🔧 keycloak-route (host kc, 1 rule)"
kubectl patch httproute keycloak-route -n keycloak --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"kc.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}}
]"

echo "🔧 openbao (host openbao, 1 rule)"
# Also repoint the backend: the chart references a non-existent "openbao-ui" service;
# the deployed OpenBao chart only exposes the "openbao" service (plain HTTP on 8200).
# A wrong backendRef makes Traefik return an empty 500.
kubectl patch httproute openbao -n cf-openbao --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"openbao.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/name\",\"value\":\"openbao\"},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/port\",\"value\":8200}
]"

echo "🔧 minio (host minio, 1 rule)"
kubectl patch httproute minio -n minio-tenant-default --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"minio.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}}
]"

echo "🔧 grafana-route (host grafana, 1 rule)"
kubectl patch httproute grafana-route -n otel-lgtm-stack --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/hostnames\",\"value\":[\"grafana.${DOMAIN}\"]},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/matches\",\"value\":${PP}}
]"

echo ""
echo "=== Resulting hostnames ==="
kubectl get httproute -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hostnames'

echo ""
echo "=== Gateway attached routes ==="
kubectl get gateway https -n envoy-gateway-system \
  -o jsonpath='listeners:{range .status.listeners[*]} {.name}(attached={.attachedRoutes}){end}{"\n"}'

echo ""
echo "Waiting 5s for Traefik to reconcile the route changes..."
sleep 5

echo ""
echo "=== Connectivity test (via in-cluster LB IP to avoid hairpin NAT) ==="
LB_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for h in aiwbui aiwbapi kc openbao minio grafana; do
  fqdn="${h}.${DOMAIN}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' --resolve "${fqdn}:443:${LB_IP}" "https://${fqdn}/" || echo "ERR")
  echo "  ${fqdn} -> ${code}"
done

echo ""
echo "✅ Done. Any code other than 404 means routing works (200/302/307/403 are all fine)."
