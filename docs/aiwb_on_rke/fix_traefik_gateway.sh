#!/usr/bin/env bash
#
# Live fix for: Traefik Gateway provider stuck Pending (GatewayClass/Gateway
# PROGRAMMED=Unknown, HTTPRoutes never attach -> 404).
#
# Cause: Traefik's Gateway provider watches TLSRoute/TCPRoute/BackendTLSPolicy,
# which are NOT in the Gateway API "standard" channel. Their absence makes
# Traefik's informers fail to sync. Installing the "experimental" channel
# (a superset of standard) and restarting Traefik fixes it.
#
# Run on the cluster (root kubeconfig):  sudo bash fix_traefik_gateway.sh
set -euo pipefail

# Traefik v3.7 supports Gateway API v1.5.1 and watches TLSRoute/BackendTLSPolicy at
# their v1 versions; older CRDs (e.g. v1.2.1, which serve v1alpha2/v1alpha3) cause
# "could not find the requested resource" and leave the GatewayClass Pending.
GW_API_VERSION="${GW_API_VERSION:-v1.5.1}"
TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
GATEWAY_NS="${GATEWAY_NS:-envoy-gateway-system}"

echo "📦 Installing Gateway API CRDs (experimental channel ${GW_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/experimental-install.yaml"

echo "⏳ Waiting for the experimental CRDs to be established..."
kubectl wait --for=condition=established --timeout=60s \
  crd/tlsroutes.gateway.networking.k8s.io \
  crd/tcproutes.gateway.networking.k8s.io \
  crd/backendtlspolicies.gateway.networking.k8s.io

echo "🔄 Restarting Traefik so its informers re-sync..."
kubectl -n "${TRAEFIK_NS}" rollout restart deploy traefik
kubectl -n "${TRAEFIK_NS}" rollout status deploy traefik --timeout=180s

echo "⏳ Giving the Gateway provider a few seconds to reconcile..."
sleep 10

echo ""
echo "=== GatewayClass traefik ==="
kubectl get gatewayclass traefik \
  -o jsonpath='accepted={.status.conditions[?(@.type=="Accepted")].status} reason={.status.conditions[?(@.type=="Accepted")].reason}{"\n"}'

echo "=== Gateway https (-n ${GATEWAY_NS}) ==="
kubectl get gateway https -n "${GATEWAY_NS}" \
  -o jsonpath='programmed={.status.conditions[?(@.type=="Programmed")].status} reason={.status.conditions[?(@.type=="Programmed")].reason}{"\n"}listeners:{range .status.listeners[*]} {.name}(attached={.attachedRoutes}){end}{"\n"}'

echo "=== HTTPRoutes (all namespaces) ==="
kubectl get httproute -A

echo ""
echo "✅ Done. If PROGRAMMED=True and attached>0, test:"
echo "   curl -sS -o /dev/null -w 'http=%{http_code}\\n' https://kc.aiwb-test.silogen.ai"
