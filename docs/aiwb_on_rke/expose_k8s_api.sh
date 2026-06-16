#!/usr/bin/env bash
#
# Expose the Kubernetes API server (6443) through the Traefik Gateway on the
# external 443 port, addressed as k8s.<domain>, using TLS PASSTHROUGH — so you
# can run kubectl from your laptop against https://k8s.<domain>.
#
# Why passthrough (TLSRoute) and NOT an HTTPRoute:
#   kubectl authenticates with a client certificate (mTLS). If the gateway
#   terminated TLS (HTTPRoute / HTTPS listener), the client cert would never
#   reach the API server and auth would fail. A TLSRoute with mode: Passthrough
#   makes Traefik route by SNI only and forward the raw TLS stream to the
#   apiserver, which then does its own mTLS — exactly what kubectl needs.
#
# Note: create_rke.sh adds "k8s.<domain>" to the apiserver cert SANs (tls-san),
# so TLS verification works without --insecure-skip-tls-verify.
#
# Run on the cluster (root kubeconfig):  sudo bash expose_k8s_api.sh <DOMAIN>
set -euo pipefail

# Require DOMAIN as the first argument (no default).
if [ -z "${1:-}" ]; then
  echo "❌ Error: DOMAIN parameter is required" >&2
  echo "" >&2
  echo "Usage: $0 <DOMAIN>" >&2
  exit 1
fi
DOMAIN="$1"

GATEWAY_NS="${GATEWAY_NS:-envoy-gateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-https}"
LISTENER_NAME="${LISTENER_NAME:-k8s-passthrough}"
LISTENER_PORT="${LISTENER_PORT:-8443}"     # internal entrypoint port (externally 443)
TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
APISERVER_HOST="k8s.${DOMAIN}"

echo "🔧 Ensuring Gateway '${GATEWAY_NAME}' has a TLS-passthrough listener '${LISTENER_NAME}' for ${APISERVER_HOST}..."
if kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NS}" \
     -o jsonpath="{.spec.listeners[?(@.name=='${LISTENER_NAME}')].name}" | grep -q "${LISTENER_NAME}"; then
  echo "ℹ️  Listener '${LISTENER_NAME}' already present — skipping add."
else
  kubectl patch gateway "${GATEWAY_NAME}" -n "${GATEWAY_NS}" --type=json -p="[
    {\"op\":\"add\",\"path\":\"/spec/listeners/-\",\"value\":{
       \"name\":\"${LISTENER_NAME}\",
       \"hostname\":\"${APISERVER_HOST}\",
       \"port\":${LISTENER_PORT},
       \"protocol\":\"TLS\",
       \"tls\":{\"mode\":\"Passthrough\"},
       \"allowedRoutes\":{
          \"namespaces\":{\"from\":\"All\"},
          \"kinds\":[{\"group\":\"gateway.networking.k8s.io\",\"kind\":\"TLSRoute\"}]
       }
    }}
  ]"
fi

echo "🔧 Creating TLSRoute 'k8s-api' (default ns, same ns as the kubernetes Service — no ReferenceGrant needed)..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: k8s-api
  namespace: default
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY_NAME}
      namespace: ${GATEWAY_NS}
      sectionName: ${LISTENER_NAME}
  hostnames:
    - "${APISERVER_HOST}"
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: kubernetes
          port: 443
EOF

echo "🔄 Restarting Traefik so it picks up the new listener/route cleanly..."
kubectl -n "${TRAEFIK_NS}" rollout restart deploy traefik
kubectl -n "${TRAEFIK_NS}" rollout status deploy traefik --timeout=180s

echo "⏳ Giving the Gateway provider a few seconds to reconcile..."
sleep 8

echo ""
echo "=== Gateway listeners ==="
kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NS}" \
  -o jsonpath='{range .status.listeners[*]}{.name}: programmed={.conditions[?(@.type=="Programmed")].status} attached={.attachedRoutes}{"\n"}{end}'

echo "=== TLSRoute status ==="
kubectl get tlsroute k8s-api -n default \
  -o jsonpath='accepted={.status.parents[0].conditions[?(@.type=="Accepted")].status} resolvedRefs={.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'

echo ""
echo "=== Validation: does SNI=${APISERVER_HOST} pass through to the API server? ==="
LB_IP=$(kubectl get svc traefik -n "${TRAEFIK_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LB_IP=${LB_IP}"
# Passthrough proof: the presented leaf cert should be the kube-apiserver cert,
# NOT the gateway's *.${DOMAIN} cert.
echo | openssl s_client -connect "${LB_IP}:${LISTENER_PORT}" -servername "${APISERVER_HOST}" 2>/dev/null \
  | openssl x509 -noout -subject -issuer 2>/dev/null \
  || echo "⚠️  Could not read a certificate (openssl missing or handshake failed)."

echo ""
echo "✅ If the subject/issuer above is the kube-apiserver cert (CN=kube-apiserver / rke2),"
echo "   passthrough works. If it shows '*.${DOMAIN}', it was TLS-terminated (wrong)."
echo ""
echo "👉 From your localhost:"
echo "   1) DNS: ${APISERVER_HOST} must resolve to the gateway public IP"
echo "      (the *.${DOMAIN} wildcard A record already covers this)."
echo "   2) Take the kubeconfig from /root/.kube/config and change the server to:"
echo "        server: https://${APISERVER_HOST}"
echo "      Keep certificate-authority-data as-is — verification works because"
echo "      ${APISERVER_HOST} is in the apiserver cert SANs (set by create_rke.sh)."
echo "   3) kubectl get nodes"
