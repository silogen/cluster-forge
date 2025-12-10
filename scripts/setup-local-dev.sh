#!/bin/bash

# Local Kind Development Setup Script for Cluster-Forge
# This script sets up a minimal cluster-forge deployment for local Kind clusters
#
# Environment variables:
#   SKIP_IMAGE_PRELOAD=1     - Skip pre-loading container images
#   BUILD_LOCAL_IMAGES=1     - Build and use local AIRM images instead of published ones
#   SILOGEN_CORE_PATH        - Path to silogen-core repo (auto-detected if not set)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="${1:-localhost.local}"

# Auto-detect silogen-core path if not explicitly set
if [ -z "${SILOGEN_CORE_PATH}" ]; then
    # Try to find silogen-core in parent directories (up to 2 levels)
    if [ -d "${ROOT_DIR}/../silogen-core" ]; then
        SILOGEN_CORE_PATH="${ROOT_DIR}/../silogen-core"
    elif [ -d "${ROOT_DIR}/../../silogen-core" ]; then
        SILOGEN_CORE_PATH="${ROOT_DIR}/../../silogen-core"
    else
        SILOGEN_CORE_PATH="${ROOT_DIR}/../silogen-core"  # Fallback default
    fi
fi

echo "🔧 Setting up cluster-forge for local Kind development..."
echo "📋 Domain: ${DOMAIN}"
if [ "${BUILD_LOCAL_IMAGES}" = "1" ]; then
    echo "🔨 Will build local AIRM images from: ${SILOGEN_CORE_PATH}"
fi

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

# Pre-load container images to the host Docker and load them to Kind
# to avoid re-downloading images on every cluster recreation
preload_images() {
    echo "🖼️  Pre-loading container images from Helm charts..."
    echo "   (Press Ctrl+C to skip and continue deployment)"
    
    # Temporary directory for rendered manifests
    TEMP_DIR=$(mktemp -d)
    
    # Cleanup function
    cleanup_preload() {
        echo ""
        echo "⚠️  Image pre-loading interrupted (Ctrl+C)"
        echo "🛑 Stopping deployment..."
        rm -rf "$TEMP_DIR" 2>/dev/null
        exit 130  # Standard exit code for Ctrl+C
    }
    
    # Handle Ctrl+C - exit entire script
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
    
    TOTAL=$(echo "$IMAGES" | wc -l | tr -d ' ')
    echo "Found $TOTAL unique images to pre-load"
    echo ""
    
    CURRENT=0
    FAILED=0
    LOADED=0
    INTERRUPTED=false
    
    for IMAGE in $IMAGES; do
        # Check if interrupted
        if [ "$INTERRUPTED" = "true" ]; then
            echo "Skipping remaining images..."
            break
        fi
        
        CURRENT=$((CURRENT + 1))
        
        # Skip invalid image names
        if [[ ! "$IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]]; then
            echo "[$CURRENT/$TOTAL] Skipping invalid: $IMAGE"
            FAILED=$((FAILED + 1))
            continue
        fi
        
        # Skip large AIRM/AIM images (will be pulled by Kubernetes during deployment)
        if [[ "$IMAGE" =~ amdenterpriseai/(airm-|aim-) ]]; then
            echo "[$CURRENT/$TOTAL] Skipping large image: $IMAGE"
            continue
        fi
        
        printf "[%d/%d] %s\n" "$CURRENT" "$TOTAL" "$IMAGE"
        
        # Pull to Docker if not present
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "  ⬇️  Pulling..."
            if docker pull "$IMAGE"; then
                echo "  ✅ Pulled successfully"
            else
                echo "  ⚠️  Failed to pull"
                FAILED=$((FAILED + 1))
                continue
            fi
        else
            echo "  ✓ Cached in Docker"
        fi
        
        # Load into Kind
        echo "  📦 Loading into Kind..."
        if kind load docker-image "$IMAGE" --name cluster-forge-local 2>&1 | tail -3; then
            echo "  ✅ Loaded"
            LOADED=$((LOADED + 1))
        else
            echo "  ⚠️  Failed to load"
            FAILED=$((FAILED + 1))
        fi
    done
    
    echo ""
    echo "� Loaded: $LOADED, Failed: $FAILED"
    echo "✅ Pre-loading complete!"
    echo ""
}
# Build local AIRM images from source and load into Kind
build_local_images() {
    echo "🔨 Building local AIRM images from source..."
    echo ""
    
    # Validate silogen-core path
    if [ ! -d "${SILOGEN_CORE_PATH}" ]; then
        echo "❌ Error: silogen-core repo not found at: ${SILOGEN_CORE_PATH}"
        echo "   Set SILOGEN_CORE_PATH environment variable to the correct path"
        exit 1
    fi
    
    local DOCKER_DIR="${SILOGEN_CORE_PATH}/services/airm/docker"
    if [ ! -d "${DOCKER_DIR}" ]; then
        echo "❌ Error: Docker directory not found at: ${DOCKER_DIR}"
        exit 1
    fi
    
    echo "📂 Source: ${SILOGEN_CORE_PATH}"
    echo ""
    
    # Build images
    # Note: UI build is skipped as it takes a very long time (Next.js build with all dependencies)
    # Use the published image for UI, or build manually if needed:
    #   cd ${SILOGEN_CORE_PATH}/services/airm/ui && docker build -f ../docker/ui.Dockerfile -t amdenterpriseai/airm-ui:local .
    local IMAGES=(
        "api:amdenterpriseai/airm-api:local"
        "dispatcher:amdenterpriseai/airm-dispatcher:local"
        # "ui:amdenterpriseai/airm-ui:local"  # Skipped - very slow build
    )
    
    local BUILT=0
    local FAILED=0
    
    for IMAGE_SPEC in "${IMAGES[@]}"; do
        local SERVICE="${IMAGE_SPEC%%:*}"
        local IMAGE_TAG="${IMAGE_SPEC#*:}"
        local DOCKERFILE="${DOCKER_DIR}/${SERVICE}.Dockerfile"
        
        echo "🏗️  Building ${SERVICE}..."
        echo "   Image: ${IMAGE_TAG}"
        echo "   Dockerfile: ${DOCKERFILE}"
        
        if [ ! -f "${DOCKERFILE}" ]; then
            echo "   ❌ Dockerfile not found!"
            FAILED=$((FAILED + 1))
            continue
        fi
        
        # UI uses its own directory as build context, others use repo root
        local BUILD_CONTEXT="${SILOGEN_CORE_PATH}"
        if [ "${SERVICE}" = "ui" ]; then
            BUILD_CONTEXT="${SILOGEN_CORE_PATH}/services/airm/ui"
        fi
        
        echo "   Building..."
        if docker build \
            -f "${DOCKERFILE}" \
            -t "${IMAGE_TAG}" \
            "${BUILD_CONTEXT}"; then
            echo "   ✅ Built successfully"
            BUILT=$((BUILT + 1))
        else
            echo "   ❌ Build failed"
            FAILED=$((FAILED + 1))
            continue
        fi
        
        # Load into Kind
        echo "   📦 Loading into Kind..."
        if kind load docker-image "${IMAGE_TAG}" --name cluster-forge-local; then
            echo "   ✅ Loaded into Kind"
        else
            echo "   ❌ Failed to load into Kind"
            FAILED=$((FAILED + 1))
        fi
        echo ""
    done
    
    echo "📊 Results: Built $BUILT, Failed: $FAILED"
    
    if [ $FAILED -gt 0 ]; then
        echo "⚠️  Some images failed to build"
        exit 1
    fi
    
    echo "✅ Local images built and loaded!"
    echo ""
}

# Pre-load images (skip with SKIP_IMAGE_PRELOAD=1)
if [ "${SKIP_IMAGE_PRELOAD:-0}" = "1" ]; then
    echo "⏭️  Skipping image pre-load (SKIP_IMAGE_PRELOAD=1)"
else
    preload_images || echo "⚠️  Image pre-loading failed, continuing anyway..."
fi

# Build local images (only if BUILD_LOCAL_IMAGES=1)
if [ "${BUILD_LOCAL_IMAGES}" = "1" ]; then
    build_local_images
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

echo "📤 Pushing repositories to Gitea..."

# Push cluster-forge repo
"${ROOT_DIR}/scripts/push-repo-to-gitea.sh" "${ROOT_DIR}" "cluster-org" "cluster-forge"

# Push silogen-core repo if it exists
if [ -d "${SILOGEN_CORE_PATH}" ]; then
    "${ROOT_DIR}/scripts/push-repo-to-gitea.sh" "${SILOGEN_CORE_PATH}" "cluster-org" "core"
else
    echo "⚠️  silogen-core not found at ${SILOGEN_CORE_PATH}"
    echo "   AIRM will use charts from cluster-forge/sources/airm/0.2.7"
fi

echo "✅ Repositories pushed to Gitea"

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