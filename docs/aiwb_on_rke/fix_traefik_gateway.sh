#!/usr/bin/env bash
#
# Live fix for: Traefik Gateway provider stuck Pending (GatewayClass/Gateway
# PROGRAMMED=Unknown/NotValid, HTTPRoutes never attach -> 404 / hang).
#
# Two root causes, both fixed here:
#  1) CRD VERSION: Traefik v3.7 supports Gateway API v1.5.1 and watches
#     TLSRoute/BackendTLSPolicy at their v1 versions. Older CRDs (e.g. v1.2.1,
#     serving v1alpha2/v1alpha3) make Traefik's informers fail ("could not find
#     the requested resource") and the GatewayClass stays Pending. Install the
#     experimental channel (superset of standard; also provides TCPRoute).
#  2) LISTENER PORT: Traefik maps Gateway listeners to entryPoints by port. The
#     default 'websecure' entryPoint is 8443 (the Service maps external 443->8443);
#     a listener on 443 fails with PortUnavailable. Patch the listener to 8443.
#     External access stays on 443 via the Service.
#
# Run on the cluster (root kubeconfig):  sudo bash fix_traefik_gateway.sh
set -euo pipefail

GW_API_VERSION="${GW_API_VERSION:-v1.5.1}"
TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
GATEWAY_NS="${GATEWAY_NS:-envoy-gateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-https}"
LISTENER_PORT="${LISTENER_PORT:-8443}"

echo "📦 Installing Gateway API CRDs (experimental channel ${GW_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/experimental-install.yaml"

echo "⏳ Waiting for the experimental CRDs to be established..."
kubectl wait --for=condition=established --timeout=60s \
  crd/tlsroutes.gateway.networking.k8s.io \
  crd/tcproutes.gateway.networking.k8s.io \
  crd/backendtlspolicies.gateway.networking.k8s.io

echo "🔧 Ensuring Gateway '${GATEWAY_NAME}' listener[0] uses port ${LISTENER_PORT} (matches Traefik websecure entryPoint)..."
kubectl patch gateway "${GATEWAY_NAME}" -n "${GATEWAY_NS}" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/port\",\"value\":${LISTENER_PORT}}]"

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
