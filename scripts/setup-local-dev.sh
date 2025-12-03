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

# Pre-load container images
preload_images() {
    echo "🖼️  Pre-loading container images from Helm charts..."
    echo "   (Press Ctrl+C to skip and continue deployment)"
    
    # Temporary directory for rendered manifests
    TEMP_DIR=$(mktemp -d)
    
    # Cleanup function
    cleanup_preload() {
        echo ""
        echo "⚠️  Image pre-loading interrupted (Ctrl+C)"
        # Kill all background jobs
        jobs -p | xargs -r kill 2>/dev/null || true
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        exit 1
    }
    
    # Handle Ctrl+C gracefully
    trap cleanup_preload INT TERM
    trap "rm -rf $TEMP_DIR" EXIT
    
    echo "📋 Discovering charts from cluster-forge..."
    
    # Render cluster-forge to get the list of source paths
    helm template cluster-forge root/ \
        --values root/values_local_kind.yaml \
        > "$TEMP_DIR/cluster-forge.yaml" 2>/dev/null
    
    # Extract source paths that will actually be deployed
    CHART_PATHS=$(grep "path: sources/" "$TEMP_DIR/cluster-forge.yaml" | \
        sed 's/.*path:[[:space:]]*\(sources\/[^[:space:]]*\).*/\1/' | \
        sort -u)
    
    if [ -z "$CHART_PATHS" ]; then
        echo "⚠️  No chart paths found, skipping pre-load"
        return 0
    fi
    
    echo "Found $(echo "$CHART_PATHS" | wc -l | tr -d ' ') charts to render"
    echo ""
    
    # Render each chart that will be deployed
    for CHART_PATH in $CHART_PATHS; do
        if [ -f "$CHART_PATH/Chart.yaml" ]; then
            CHART_NAME=$(basename "$CHART_PATH")
            echo "  Rendering $CHART_NAME..."
            
            VALUES_FILE="$CHART_PATH/values.yaml"
            if [ -f "$VALUES_FILE" ]; then
                helm template "$CHART_NAME" "$CHART_PATH" \
                    --values "$VALUES_FILE" \
                    >> "$TEMP_DIR/all-manifests.yaml" 2>/dev/null || echo "    ⚠️  Failed to render"
            fi
        fi
    done
    
    # Extract all unique images from rendered manifests
    echo ""
    echo "📦 Extracting images from manifests..."
    IMAGES=$(cat "$TEMP_DIR"/*.yaml 2>/dev/null | \
        grep -E "^\s+image:\s+" | \
        sed -E 's/.*image:[[:space:]]+([^[:space:]]+).*/\1/' | \
        sed 's/^["'\'']*//;s/["'\'']*$//' | \
        grep -v "{{" | \
        grep -v "^image:$" | \
        grep "/" | \
        sort -u)
    
    if [ -z "$IMAGES" ]; then
        echo "⚠️  No images found in rendered manifests"
        return 0
    fi
    
    MAX_PARALLEL=5
    TOTAL=$(echo "$IMAGES" | wc -l | tr -d ' ')
    echo "Found $TOTAL unique images to pre-load"
    echo "Pulling up to $MAX_PARALLEL images in parallel..."
    echo ""
    
    CURRENT=0
    
    # Process images in parallel batches
    while IFS= read -r IMAGE; do
        CURRENT=$((CURRENT + 1))
        
        # Skip invalid image names
        if [[ ! "$IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]]; then
            echo "[$CURRENT/$TOTAL] Skipping invalid: $IMAGE"
            continue
        fi
        
        # Wait for a slot to open if we're at max parallel
        while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]; do
            sleep 0.1
        done
        
        # Start background job to pull and load one image
        (
            NUM=$CURRENT
            printf "[%d/%d] %s\n" "$NUM" "$TOTAL" "$IMAGE"
            
            # Pull to Docker if not present
            if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
                echo "  ⬇️  Pulling..."
                if docker pull "$IMAGE" >/dev/null 2>&1; then
                    echo "  ✅ Pulled"
                else
                    echo "  ⚠️  Failed to pull"
                    exit 1
                fi
            else
                echo "  ✓ Already cached"
            fi
            
            # Load into Kind
            echo "  📦 Loading into Kind..."
            if kind load docker-image "$IMAGE" --name cluster-forge-local >/dev/null 2>&1; then
                echo "  ✅ Loaded"
            else
                echo "  ⚠️  Failed to load"
                exit 1
            fi
        ) &
    done <<< "$IMAGES"
    
    # Wait for all background jobs
    echo ""
    echo "⏳ Waiting for all image operations to complete..."
    wait
    
    # Count results
    LOADED=$(docker exec cluster-forge-local-control-plane ctr --namespace k8s.io images ls -q 2>/dev/null | wc -l | tr -d ' ')
    
    echo ""
    echo "📊 Total images in Kind cluster: $LOADED"
    echo "✅ Pre-loading complete!"
    echo ""
}

# Pre-load images (skip with SKIP_IMAGE_PRELOAD=1)
if [ "${SKIP_IMAGE_PRELOAD:-0}" = "1" ]; then
    echo "⏭️  Skipping image pre-load (SKIP_IMAGE_PRELOAD=1)"
else
    preload_images || echo "⚠️  Image pre-loading failed, continuing anyway..."
fi

# Bootstrap components in parallel
echo "🚀 Deploying ArgoCD, OpenBao, and Gitea in parallel..."

# Deploy ArgoCD
(
    helm template --release-name argocd sources/argocd/8.3.5 \
      -f sources/argocd/values_cf.yaml \
      --namespace argocd \
      --set global.domain="https://argocd.${DOMAIN}" \
      --kube-version=1.33 | kubectl apply -f - 2>&1 | sed 's/^/[ArgoCD] /'
) &
ARGOCD_PID=$!

# Deploy OpenBao
(
    helm template --release-name openbao sources/openbao/0.18.2 \
      -f sources/openbao/values_cf.yaml \
      --namespace cf-openbao \
      --kube-version=1.33 | kubectl apply -f - 2>&1 | sed 's/^/[OpenBao] /'
) &
OPENBAO_PID=$!

# Prepare Gitea secrets
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password) \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

kubectl create configmap initial-cf-values \
  --from-file=initial-cf-values=root/values_local_kind.yaml \
  -n cf-gitea \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

# Deploy Gitea
(
    helm template --release-name gitea sources/gitea/12.3.0 \
      -f sources/gitea/values_cf.yaml \
      --namespace cf-gitea \
      --set clusterDomain="${DOMAIN}" \
      --set gitea.config.server.ROOT_URL="http://gitea.${DOMAIN}" \
      --kube-version=1.33 | kubectl apply -f - 2>&1 | sed 's/^/[Gitea] /'
) &
GITEA_PID=$!

# Wait for all deployments to complete
echo "⏳ Waiting for parallel deployments to apply..."
wait $ARGOCD_PID $OPENBAO_PID $GITEA_PID

echo "⏳ Waiting for all components to become ready..."

# Wait for ArgoCD
echo "  Waiting for ArgoCD..."
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd > /dev/null 2>&1 &
WAIT_ARGOCD_SERVER=$!

kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s > /dev/null 2>&1 &
WAIT_ARGOCD_CONTROLLER=$!

kubectl rollout status deploy/argocd-redis -n argocd --timeout=600s > /dev/null 2>&1 &
WAIT_ARGOCD_REDIS=$!

kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=600s > /dev/null 2>&1 &
WAIT_ARGOCD_REPO=$!

# Wait for OpenBao
echo "  Waiting for OpenBao..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=600s > /dev/null 2>&1 &
WAIT_OPENBAO=$!

# Wait for Gitea
echo "  Waiting for Gitea..."
kubectl rollout status deploy/gitea -n cf-gitea --timeout=600s > /dev/null 2>&1 &
WAIT_GITEA=$!

# Wait for all readiness checks
wait $WAIT_ARGOCD_SERVER $WAIT_ARGOCD_CONTROLLER $WAIT_ARGOCD_REDIS $WAIT_ARGOCD_REPO
echo "✅ ArgoCD is ready"

wait $WAIT_OPENBAO
echo "✅ OpenBao is ready"

wait $WAIT_GITEA
echo "✅ Gitea is ready"

# Initialize OpenBao
echo "🔧 Initializing OpenBao..."
helm template --release-name openbao-init scripts/init-openbao-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f - > /dev/null

kubectl wait --for=condition=complete --timeout=600s job/openbao-init-job -n cf-openbao > /dev/null 2>&1 &
WAIT_OPENBAO_INIT=$!

# Initialize Gitea
echo "🔧 Initializing Gitea..."
helm template --release-name gitea-init scripts/init-gitea-local-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f - > /dev/null

kubectl wait --for=condition=complete --timeout=600s job/gitea-init-local-job -n cf-gitea > /dev/null 2>&1 &
WAIT_GITEA_INIT=$!

# Wait for both init jobs
wait $WAIT_OPENBAO_INIT
echo "✅ OpenBao initialized"

wait $WAIT_GITEA_INIT
echo "✅ Gitea initialized"

echo "📤 Pushing local repository to Gitea..."
# Get Gitea admin credentials
GITEA_USER=$(kubectl get secret gitea-admin-credentials -n cf-gitea -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(kubectl get secret gitea-admin-credentials -n cf-gitea -o jsonpath='{.data.password}' | base64 -d)
GITEA_URL="http://gitea.${DOMAIN}:3000"

# Add Gitea as a remote and push (via port-forward)
kubectl port-forward -n cf-gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

# Configure git if needed
git remote remove gitea-local 2>/dev/null || true
git remote add gitea-local "http://${GITEA_USER}:${GITEA_PASS}@localhost:3000/cluster-org/cluster-forge.git"

# Push current branch to main
echo "Pushing $(git branch --show-current) to Gitea main branch..."
git push gitea-local HEAD:main --force

# Cleanup
kill $PF_PID 2>/dev/null || true
git remote remove gitea-local

echo "✅ Repository pushed to Gitea"

# Deploy cluster-forge ArgoCD applications
echo "🎯 Deploying cluster-forge ArgoCD applications..."
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