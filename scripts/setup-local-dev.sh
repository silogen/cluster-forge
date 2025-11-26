#!/bin/bash

# Local Kind Development Setup Script for Cluster-Forge
# This script sets up a minimal cluster-forge deployment for local Kind clusters

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="${1:-localhost.local}"

echo "🔧 Setting up cluster-forge for local Kind development..."
echo "📋 Domain: ${DOMAIN}"

# Check if kind cluster exists
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ ERROR: No Kubernetes cluster found. Please create a Kind cluster first:"
    echo "   kind create cluster --name cluster-forge-local --config options/local-kind.yaml"
    exit 1
fi

# Apply AMD certificates if fix_kind_certs.sh exists
if [ -f "${SCRIPT_DIR}/fix_kind_certs.sh" ]; then
    echo "🔐 Applying AMD certificates to Kind cluster..."
    bash "${SCRIPT_DIR}/fix_kind_certs.sh"
fi

# Check prerequisites
echo "🔍 Checking prerequisites..."
for cmd in kubectl helm yq openssl; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ ERROR: $cmd is not installed"
        exit 1
    fi
done

cd "${ROOT_DIR}"

# Update domain in values file
echo "📝 Updating domain to ${DOMAIN} in values_local_kind.yaml..."
yq eval '.global.domain = "'${DOMAIN}'"' -i root/values_local_kind.yaml

# Create namespaces
echo "📦 Creating namespaces..."
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns airm --dry-run=client -o yaml | kubectl apply -f -

# Create default storage class for compatibility
echo "💾 Creating default StorageClass..."
kubectl create -f - <<EOF || true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
EOF

# Bootstrap ArgoCD
echo "🚀 Deploying ArgoCD..."
helm template --release-name argocd sources/argocd/8.3.5 \
  -f sources/argocd/values_cf.yaml \
  --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

echo "⏳ Waiting for ArgoCD to be ready..."
if ! kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd 2>&1; then
    echo "⚠️  WARNING: argocd-server deployment not ready, continuing anyway..."
    kubectl get pods -n argocd
fi

if ! kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s 2>&1; then
    echo "⚠️  WARNING: application-controller not ready, continuing anyway..."
fi

if ! kubectl rollout status deploy/argocd-redis -n argocd --timeout=180s 2>&1; then
    echo "⚠️  WARNING: argocd-redis not ready, continuing anyway..."
fi

if ! kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=180s 2>&1; then
    echo "⚠️  WARNING: repo-server not ready, continuing anyway..."
fi

echo "✅ ArgoCD deployment phase complete"

# Bootstrap OpenBao
echo "🔐 Deploying OpenBao..."
helm template --release-name openbao sources/openbao/0.18.2 \
  -f sources/openbao/values_cf.yaml \
  --namespace cf-openbao \
  --kube-version=1.33 | kubectl apply -f -

echo "⏳ Waiting for OpenBao to be ready..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s 2>&1; then
    echo "❌ ERROR: OpenBao pod failed to start. Checking status:"
    kubectl get pods -n cf-openbao
    kubectl describe pod/openbao-0 -n cf-openbao | tail -30
    exit 1
fi

echo "🔧 Initializing OpenBao..."
helm template --release-name openbao-init scripts/init-openbao-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

if ! kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao 2>&1; then
    echo "❌ ERROR: OpenBao initialization failed. Check logs:"
    kubectl logs -n cf-openbao job/openbao-init-job --tail=50
    exit 1
fi

# Bootstrap Gitea
echo "📚 Deploying Gitea..."

# Generate admin password
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password) \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap initial-cf-values \
  --from-file=initial-cf-values=root/values_local_kind.yaml \
  -n cf-gitea \
  --dry-run=client -o yaml | kubectl apply -f -

helm template --release-name gitea sources/gitea/12.3.0 \
  -f sources/gitea/values_cf.yaml \
  --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" \
  --set gitea.config.server.ROOT_URL="http://gitea.${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

echo "⏳ Waiting for Gitea to be ready..."
if ! kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s 2>&1; then
    echo "❌ ERROR: Gitea deployment failed. Checking status:"
    kubectl get pods -n cf-gitea
    kubectl logs -n cf-gitea deployment/gitea --tail=50
    exit 1
fi

echo "🔧 Initializing Gitea repositories..."
helm template --release-name gitea-init scripts/init-gitea-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

if ! kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea 2>&1; then
    echo "❌ ERROR: Gitea initialization failed. Check logs:"
    kubectl logs -n cf-gitea job/gitea-init-job --tail=50
    exit 1
fi

# Deploy cluster-forge ArgoCD application
echo "🎯 Deploying cluster-forge ArgoCD application..."
helm template root -f root/values_local_kind.yaml \
  --set global.domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

echo ""
echo "✅ Local Kind cluster-forge setup complete!"
echo ""
echo "📊 Checking deployment status..."
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null | head -20

echo ""
echo "⏳ Key applications status (may take a few minutes to sync):"
echo "   MinIO: $(kubectl get application minio-tenant -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo 'Not yet synced')"
echo "   Keycloak: $(kubectl get application keycloak -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo 'Not yet synced')"
echo "   AIRM: $(kubectl get application airm -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo 'Not yet synced')"
echo ""
echo "⚠️  Resource Warning:"
echo "   AIRM and all dependencies require significant resources."
echo "   If pods are pending due to insufficient CPU/memory, consider:"
echo "   - Commenting out some apps in root/values_local_kind.yaml"
echo "   - Using a multi-node Kind cluster"
echo "   - Increasing Docker Desktop resource limits"
echo ""
echo "📋 Access Information:"
echo ""
echo "1. ArgoCD UI:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Open: https://localhost:8080 (accept self-signed cert)"
echo "   Username: admin"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo "2. Gitea UI:"
echo "   kubectl port-forward svc/gitea-http -n cf-gitea 3000:3000"
echo "   Open: http://localhost:3000"
echo "   Username: kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath=\"{.data.username}\" | base64 -d"
echo "   Password: kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo "3. OpenBao UI:"
echo "   kubectl port-forward svc/openbao-active -n cf-openbao 8200:8200"
echo "   Open: http://localhost:8200"
echo "   Token: kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.root_token}' | base64 -d"
echo ""
echo "💡 Tips:"
echo "   - Monitor ArgoCD apps: kubectl get applications -n argocd"
echo "   - Check sync status: argocd app list"
echo "   - View logs: kubectl logs -n <namespace> <pod-name>"
echo ""