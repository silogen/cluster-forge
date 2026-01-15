#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${1:-}"
VALUES_FILE="${2:-values.yaml}"
KUBE_VERSION=1.33

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Helper functions for idempotent operations
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-}"
    
    if [ -n "$namespace" ]; then
        kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1
    else
        kubectl get "$resource_type" "$resource_name" >/dev/null 2>&1
    fi
}

deployment_ready() {
    local deployment="$1"
    local namespace="$2"
    
    if ! resource_exists "deployment" "$deployment" "$namespace"; then
        return 1
    fi
    
    local ready=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    [ "$ready" = "$desired" ] && [ "$ready" != "0" ]
}

statefulset_ready() {
    local statefulset="$1" 
    local namespace="$2"
    
    if ! resource_exists "statefulset" "$statefulset" "$namespace"; then
        return 1
    fi
    
    local ready=$(kubectl get statefulset "$statefulset" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get statefulset "$statefulset" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    [ "$ready" = "$desired" ] && [ "$ready" != "0" ]
}

job_completed() {
    local job="$1"
    local namespace="$2"
    
    if ! resource_exists "job" "$job" "$namespace"; then
        return 1
    fi
    
    local conditions=$(kubectl get job "$job" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    [ "$conditions" = "True" ]
}

# Safe kubectl apply that handles conflicts
safe_kubectl_apply() {
    local manifest="$1"
    echo "$manifest" | kubectl apply -f - --validate=false --force-conflicts --server-side=true 2>/dev/null || {
        echo "Warning: Some resources may already exist, continuing..."
        echo "$manifest" | kubectl apply -f - --validate=false 2>/dev/null || true
    }
}

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD bootstrap
echo "🚀 Bootstrapping ArgoCD..."

# Check if ArgoCD is already ready
if statefulset_ready "argocd-application-controller" "argocd" && \
   deployment_ready "argocd-applicationset-controller" "argocd" && \
   deployment_ready "argocd-redis" "argocd" && \
   deployment_ready "argocd-repo-server" "argocd"; then
    echo "✅ ArgoCD already deployed and ready"
else
    # Create temporary merged values file for ArgoCD
    ARGOCD_MERGED_CONFIG="/tmp/bootstrap-argocd-$$.yaml"
    echo "apps:" > "$ARGOCD_MERGED_CONFIG"
    echo "  argocd:" >> "$ARGOCD_MERGED_CONFIG" 
    echo "    valuesObject: {}" >> "$ARGOCD_MERGED_CONFIG"

    # Merge valuesObject from the root values file
    if yq -e '.apps.argocd.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.argocd.valuesObject *= select(fileIndex == 1).apps.argocd.valuesObject' \
        "$ARGOCD_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${ARGOCD_MERGED_CONFIG}.tmp"
      mv "${ARGOCD_MERGED_CONFIG}.tmp" "$ARGOCD_MERGED_CONFIG"
    fi

    echo "📦 Deploying ArgoCD components..."
    ARGOCD_MANIFEST=$(helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \
      --values <(yq '.apps.argocd.valuesObject' "$ARGOCD_MERGED_CONFIG") \
      --namespace argocd \
      --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION})
    
    safe_kubectl_apply "$ARGOCD_MANIFEST"
    rm -f "$ARGOCD_MERGED_CONFIG"

    echo "⏳ Waiting for ArgoCD components to be ready..."
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
    echo "✅ ArgoCD bootstrap complete"
fi

# OpenBao bootstrap
echo "🔐 Bootstrapping OpenBao..."

# Check if OpenBao is already initialized
if resource_exists "pod" "openbao-0" "cf-openbao" && job_completed "openbao-init-job" "cf-openbao"; then
    echo "✅ OpenBao already deployed and initialized"
else
    # Clean up any problematic test pods that might be stuck
    kubectl delete pod openbao-server-test -n cf-openbao --ignore-not-found=true

    # Create temporary merged values file for OpenBao
    OPENBAO_MERGED_CONFIG="/tmp/bootstrap-openbao-$$.yaml"
    echo "apps:" > "$OPENBAO_MERGED_CONFIG"
    echo "  openbao:" >> "$OPENBAO_MERGED_CONFIG"
    echo "    valuesObject: {}" >> "$OPENBAO_MERGED_CONFIG"

    # Merge valuesObject from the root values file
    if yq -e '.apps.openbao.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.openbao.valuesObject *= select(fileIndex == 1).apps.openbao.valuesObject' \
        "$OPENBAO_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${OPENBAO_MERGED_CONFIG}.tmp"
      mv "${OPENBAO_MERGED_CONFIG}.tmp" "$OPENBAO_MERGED_CONFIG"
    fi

    echo "📦 Deploying OpenBao components..."
    OPENBAO_MANIFEST=$(helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
      --values <(yq '.apps.openbao.valuesObject' "$OPENBAO_MERGED_CONFIG") \
      --namespace cf-openbao --kube-version=${KUBE_VERSION})
    
    safe_kubectl_apply "$OPENBAO_MANIFEST"
    rm -f "$OPENBAO_MERGED_CONFIG"

    echo "⏳ Waiting for OpenBao pod to be ready..."
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

    # Handle initialization job idempotently
    if ! job_completed "openbao-init-job" "cf-openbao"; then
        echo "🔧 Running OpenBao initialization..."
        # Delete existing job if it exists but didn't complete
        kubectl delete job openbao-init-job -n cf-openbao --ignore-not-found=true
        
        INIT_MANIFEST=$(helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
        safe_kubectl_apply "$INIT_MANIFEST"
        kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
    fi
    echo "✅ OpenBao bootstrap complete"
fi

# Gitea bootstrap
echo "📚 Bootstrapping Gitea..."

generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Check if Gitea is already deployed and initialized
if deployment_ready "gitea" "cf-gitea" && job_completed "gitea-init-job" "cf-gitea"; then
    echo "✅ Gitea already deployed and initialized"
else
    # Create initial-cf-values configmap
    VALUES=$(cat ${SCRIPT_DIR}/../root/${VALUES_FILE} | yq ".global.domain = \"${DOMAIN}\"")
    kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

    # Handle admin credentials idempotently
    if resource_exists "secret" "gitea-admin-credentials" "cf-gitea"; then
        echo "🔑 Using existing Gitea admin credentials"
    else
        echo "🔑 Creating new Gitea admin credentials"
        kubectl create secret generic gitea-admin-credentials \
          --namespace=cf-gitea \
          --from-literal=username=silogen-admin \
          --from-literal=password=$(generate_password) \
          --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Create temporary merged values file for Gitea
    GITEA_MERGED_CONFIG="/tmp/bootstrap-gitea-$$.yaml"
    echo "apps:" > "$GITEA_MERGED_CONFIG"
    echo "  gitea:" >> "$GITEA_MERGED_CONFIG"
    echo "    valuesObject: {}" >> "$GITEA_MERGED_CONFIG"

    # Merge valuesObject from the root values file
    if yq -e '.apps.gitea.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.gitea.valuesObject *= select(fileIndex == 1).apps.gitea.valuesObject' \
        "$GITEA_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${GITEA_MERGED_CONFIG}.tmp"
      mv "${GITEA_MERGED_CONFIG}.tmp" "$GITEA_MERGED_CONFIG"
    fi

    echo "📦 Deploying Gitea components..."
    GITEA_MANIFEST=$(helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
      --values <(yq '.apps.gitea.valuesObject' "$GITEA_MERGED_CONFIG") \
      --namespace cf-gitea \
      --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION})
    
    safe_kubectl_apply "$GITEA_MANIFEST"
    rm -f "$GITEA_MERGED_CONFIG"

    echo "⏳ Waiting for Gitea deployment to be ready..."
    kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s

    # Handle initialization job idempotently
    if ! job_completed "gitea-init-job" "cf-gitea"; then
        echo "🔧 Running Gitea initialization..."
        # Delete existing job if it exists but didn't complete
        kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found=true
        
        INIT_MANIFEST=$(helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
        safe_kubectl_apply "$INIT_MANIFEST"
        kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea
    fi
    echo "✅ Gitea bootstrap complete"
fi

# Create cluster-forge app-of-apps
echo "🎯 Deploying Cluster-Forge applications..."
CF_MANIFEST=$(helm template ${SCRIPT_DIR}/../root -f ${SCRIPT_DIR}/../root/${VALUES_FILE} --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
safe_kubectl_apply "$CF_MANIFEST"
echo "✅ Cluster-Forge applications deployed"

echo ""
echo "🎉 Bootstrap complete! The fire of the forge eliminates impurities!"
echo "🌐 Access your services at:"
echo "   ArgoCD:  https://argocd.${DOMAIN}"
echo "   Gitea:   https://gitea.${DOMAIN}"
echo "   OpenBao: https://openbao.${DOMAIN}"