#!/bin/bash

# Local Kind Development Setup Script for Cluster-Forge
# This script sets up a minimal cluster-forge deployment for local Kind clusters
#
# Environment variables:
#   SKIP_IMAGE_PRELOAD=1     - Skip pre-loading container images
#   BUILD_LOCAL_IMAGES=1     - Build and use local AIRM images instead of published ones
#   LLM_STUDIO_CORE_PATH     - Path to llm-studio-core repo (default: ../llm-studio-core)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="${1:-localhost.local}"
LLM_STUDIO_CORE_PATH="${LLM_STUDIO_CORE_PATH:-${ROOT_DIR}/../llm-studio-core}"

echo "🔧 Setting up cluster-forge for local Kind development..."
echo "📋 Domain: ${DOMAIN}"
if [ "${BUILD_LOCAL_IMAGES}" = "1" ]; then
    echo "🔨 Will build local AIRM images from: ${LLM_STUDIO_CORE_PATH}"
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
    
    # Validate llm-studio-core path
    if [ ! -d "${LLM_STUDIO_CORE_PATH}" ]; then
        echo "❌ Error: llm-studio-core repo not found at: ${LLM_STUDIO_CORE_PATH}"
        echo "   Set LLM_STUDIO_CORE_PATH environment variable to the correct path"
        exit 1
    fi
    
    local DOCKER_DIR="${LLM_STUDIO_CORE_PATH}/services/airm/docker"
    if [ ! -d "${DOCKER_DIR}" ]; then
        echo "❌ Error: Docker directory not found at: ${DOCKER_DIR}"
        exit 1
    fi
    
    echo "📂 Source: ${LLM_STUDIO_CORE_PATH}"
    echo ""
    
    # Build images
    # Note: UI build is skipped as it takes a very long time (Next.js build with all dependencies)
    # Use the published image for UI, or build manually if needed:
    #   cd ${LLM_STUDIO_CORE_PATH}/services/airm/ui && docker build -f ../docker/ui.Dockerfile -t amdenterpriseai/airm-ui:local .
    local IMAGES=(
        "api:amdenterpriseai/airm-api:local"
        # "ui:amdenterpriseai/airm-ui:local"  # Skipped - very slow build
        "dispatcher:amdenterpriseai/airm-dispatcher:local"
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
        local BUILD_CONTEXT="${LLM_STUDIO_CORE_PATH}"
        if [ "${SERVICE}" = "ui" ]; then
            BUILD_CONTEXT="${LLM_STUDIO_CORE_PATH}/services/airm/ui"
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
    
    # Update values file to use local images
    echo "📝 Updating Helm values to use local images..."
    local VALUES_FILE="${ROOT_DIR}/root/values_local_kind.yaml"
    
    # Check if we need to add image tag parameters
    if grep -A 25 "^  airm:" "${VALUES_FILE}" | grep -q "name: airm-api.image.tag"; then
        echo "   ℹ️  Image tag overrides already present in helmParameters"
    else
        # Find the last complete helmParameter entry and add image overrides after it
        local TEMP_FILE=$(mktemp)
        awk '
        /^  airm:/ { in_airm=1 }
        in_airm && /^  [^ ]/ && !/^  airm:/ { in_airm=0 }
        in_airm && /helmParameters:/ { in_params=1 }
        # Find lines that are complete parameter entries (have both name and value on consecutive lines)
        in_airm && in_params && /^      - name:.*/ { 
            param_name=$0
            getline
            if (/^        value:/) {
                print param_name
                print
                last_complete_param=NR
            } else {
                print param_name
                print
            }
            next
        }
        {
            print
            # After the last complete parameter, insert our image overrides
            if (NR == last_complete_param && !inserted) {
                print "      - name: airm-api.api.image.tag"
                print "        value: local"
                print "      - name: airm-dispatcher.dispatcher.image.tag"
                print "        value: local"
                inserted=1
            }
        }
        ' "${VALUES_FILE}" > "${TEMP_FILE}"
        mv "${TEMP_FILE}" "${VALUES_FILE}"
        echo "   ✅ Added image tag overrides to helmParameters"
    fi
    
    echo ""
}

echo "⏳ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || true
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s || true
kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s || true
kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s || true

# Bootstrap OpenBao
echo "🔐 Deploying OpenBao..."
helm template --release-name openbao sources/openbao/0.18.2 \
  -f sources/openbao/values_cf.yaml \
  --namespace cf-openbao \
  --kube-version=1.33 | kubectl apply -f -

echo "⏳ Waiting for OpenBao to be ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

echo "🔧 Initializing OpenBao..."
helm template --release-name openbao-init scripts/init-openbao-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

if ! kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao; then
    echo "⚠️  WARNING: OpenBao initialization job did not complete. Check logs:"
    echo "   kubectl logs -n cf-openbao job/openbao-init-job"
fi

# Build local images (only if BUILD_LOCAL_IMAGES=1)
if [ "${BUILD_LOCAL_IMAGES}" = "1" ]; then
    build_local_images
fi

# Bootstrap components in parallel
echo "🚀 Deploying ArgoCD, OpenBao, and Gitea in parallel..."

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
kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s

echo "🔧 Initializing Gitea repositories..."
helm template --release-name gitea-init scripts/init-gitea-job \
  --set domain="${DOMAIN}" \
  --kube-version=1.33 | kubectl apply -f -

if ! kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea; then
    echo "⚠️  WARNING: Gitea initialization job did not complete. Check logs:"
    echo "   kubectl logs -n cf-gitea job/gitea-init-job"
fi

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

# Push llm-studio-core repo if it exists
if [ -d "${LLM_STUDIO_CORE_PATH}" ]; then
    "${ROOT_DIR}/scripts/push-repo-to-gitea.sh" "${LLM_STUDIO_CORE_PATH}" "cluster-org" "core"
else
    echo "⚠️  llm-studio-core not found at ${LLM_STUDIO_CORE_PATH}"
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