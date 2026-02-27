#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
LATEST_RELEASE="v1.8.0"
TARGET_REVISION="$LATEST_RELEASE"

CLUSTER_SIZE="medium"  # Default to medium
DOMAIN=""
KUBE_VERSION=1.33
VALUES_FILE="values.yaml"

# Parse arguments 
while [[ $# -gt 0 ]]; do
  case $1 in
    --CLUSTER-SIZE|--cluster-size|-s)
        if [ -z "$2" ]; then
          echo "ERROR: --cluster-size requires an argument"
          exit 1
        fi
        CLUSTER_SIZE="$2"
        shift 2
        ;;
      --CLUSTER-SIZE=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      --cluster-size=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      -s=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      --TARGET-REVISION|--target-revision|-r)
        if [ -z "$2" ]; then
          echo "WARNING: defaulting to --target-revision=$LATEST_RELEASE (no value specified)"
          TARGET_REVISION="$LATEST_RELEASE"
          shift
        else
          TARGET_REVISION="$2"
          shift 2
        fi
        ;;
      --TARGET-REVISION=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
      --target-revision=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
      -r=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
    --help|-h)
      cat <<HELP_OUTPUT
      Usage: $0 [options] <domain> [values_file]

      Arguments:
        domain                      Required. Cluster domain (e.g., example.com)
        values_file                 Optional. Values .yaml file to use, default: root/values.yaml
      
      Options:
        -r, --target-revision       cluster-forge git revision for ArgoCD to sync from 
                                    options: [tag|commit_hash|branch_name], default: $LATEST_RELEASE
        -s, --cluster-size          options: [small|medium|large], default: medium

      Examples:
        $0 compute.amd.com values_custom.yaml --cluster-size=large
        $0 112.100.97.17.nip.io
        $0 dev.example.com --cluster-size=small --target-revision=$LATEST_RELEASE
        $0 dev.example.com -s=small -r=$LATEST_RELEASE
        
      Bootstrap Behavior:
        • Bootstrap deploys ArgoCD + OpenBao + Gitea directly (essential infrastructure)
        • cluster-forge parent app then deployed to manage remaining apps  
        • ArgoCD syncs remaining apps from specified target revision
        • Direct deployment ensures proper initialization order and timing
HELP_OUTPUT
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      # Positional arguments
      if [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
      elif [ "$VALUES_FILE" = "values.yaml" ]; then
        VALUES_FILE="$1"
      else
        echo "ERROR: Too many arguments: $1"
        echo "Usage: $0 [--CLUSTER_SIZE=small|medium|large] [--dev] <domain> [values_file]"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate required arguments
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large]"
    echo "Use --help for more details"
    exit 1
fi

# Validate cluster size
case "$CLUSTER_SIZE" in
  small|medium|large)
    ;;
  *)
    echo "ERROR: Invalid cluster size '$CLUSTER_SIZE'"
    echo "Valid sizes: small, medium, large"
    exit 1
    ;;
esac

# Validate values file exists
if [ ! -f "${SCRIPT_DIR}/../root/${VALUES_FILE}" ]; then
    echo "ERROR: Values file not found: ${SCRIPT_DIR}/../root/${VALUES_FILE}"
    exit 1
fi

# Check if size-specific values file exists
setup_values_files() {
    SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
    
    if [ ! -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
        echo "WARNING: Size-specific values file not found: ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}"
        echo "Proceeding with base values file only: ${VALUES_FILE}"
        SIZE_VALUES_FILE=""
    else
        echo "Using size-specific values file: ${SIZE_VALUES_FILE}"
    fi
}

display_target_revision() {
  # Check if TARGET_REVISION was explicitly set via command line flag
  # by comparing against the default value
  if [ "$TARGET_REVISION" != "$LATEST_RELEASE" ]; then 
    echo "Using specified targetRevision: $TARGET_REVISION"
  else
    echo "Using default targetRevision: $TARGET_REVISION"
  fi
}

# Since we only support v1.8.0+, always use local sources
setup_sources() {
    SOURCE_ROOT="${SCRIPT_DIR}/.."
    echo "Using local sources for target revision: $TARGET_REVISION"
}

pre_cleanup() {
    echo ""
    echo "=== Pre-cleanup: Checking for previous runs ==="

    # Check if gitea-init-job exists and completed successfully
    if kubectl get job gitea-init-job -n cf-gitea >/dev/null 2>&1; then
        if kubectl get job gitea-init-job -n cf-gitea -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q "True"; then
            echo "Found completed gitea-init-job - removing Gitea to start fresh"

            # Delete all Gitea resources
            kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found=true
            kubectl delete deployment gitea -n cf-gitea --ignore-not-found=true
            kubectl delete statefulset gitea -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea-http -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea-ssh -n cf-gitea --ignore-not-found=true
            kubectl delete pvc -n cf-gitea -l app.kubernetes.io/name=gitea --ignore-not-found=true
            kubectl delete configmap initial-cf-values -n cf-gitea --ignore-not-found=true
            kubectl delete secret gitea-admin-credentials -n cf-gitea --ignore-not-found=true
            kubectl delete ingress -n cf-gitea -l app.kubernetes.io/name=gitea --ignore-not-found=true

            echo "Gitea resources deleted"
        fi
    fi

    # Always delete openbao-init-job to allow re-initialization
    kubectl delete job openbao-init-job -n cf-openbao --ignore-not-found=true

    # Delete temporary files
    rm -f /tmp/merged_values.yaml /tmp/argocd_values.yaml /tmp/argocd_size_values.yaml \
      /tmp/openbao_values.yaml /tmp/openbao_size_values.yaml \
      /tmp/gitea_values.yaml /tmp/gitea_size_values.yaml

    echo "=== Pre-cleanup complete ==="
    echo ""
}

display_target_revision
setup_sources
setup_values_files

# Run pre-cleanup
# pre_cleanup

echo "=== ClusterForge Bootstrap ==="
echo "Domain: $DOMAIN"
echo "Base values: $VALUES_FILE"
echo "Cluster size: $CLUSTER_SIZE"
if [ -n "$SIZE_VALUES_FILE" ]; then
    echo "Size overlay: $SIZE_VALUES_FILE"
fi
echo "Target revision: $TARGET_REVISION"
echo ""
echo "=== Starting Bootstrap Process ==="

# Extract version information from app paths using sed/awk (no yq needed)
extract_app_versions() {
    # Extract ArgoCD version from path like "sources/argocd/8.3.5"
    ARGOCD_VERSION=$(grep -A 5 "^  argocd:" "${SOURCE_ROOT}/root/${VALUES_FILE}" | \
        grep "path:" | sed 's/.*argocd\///' | sed 's/ *$//')
    
    # Extract OpenBao version from path like "sources/openbao/0.18.2"
    OPENBAO_VERSION=$(grep -A 5 "^  openbao:" "${SOURCE_ROOT}/root/${VALUES_FILE}" | \
        grep "path:" | sed 's/.*openbao\///' | sed 's/ *$//')
    
    # Extract Gitea version from path like "sources/gitea/12.3.0"  
    GITEA_VERSION=$(grep -A 5 "^  gitea:" "${SOURCE_ROOT}/root/${VALUES_FILE}" | \
        grep "path:" | sed 's/.*gitea\///' | sed 's/ *$//')
    
    echo "Extracted versions - ArgoCD: $ARGOCD_VERSION, OpenBao: $OPENBAO_VERSION, Gitea: $GITEA_VERSION"
}

# Note: clusterForge.targetRevision will be set by the gitea-init-job
# in the cluster-values repository (which overwrites the base values as the final values file)
echo "Target revision $TARGET_REVISION will be set in cluster-values repo by gitea-init-job"

# Extract version information from values
extract_app_versions

# Create namespaces for direct deployments only
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
# Note: cf-openbao namespace will be created by ArgoCD when it deploys OpenBao

echo ""
echo "=== ArgoCD Bootstrap ==="
# Deploy ArgoCD using dedicated values file (no yq extraction needed)
helm template --release-name argocd ${SOURCE_ROOT}/sources/argocd/${ARGOCD_VERSION} --namespace argocd \
  -f ${SOURCE_ROOT}/root/values_argocd.yaml \
  --set global.domain="argocd.${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

echo ""
echo "=== OpenBao Bootstrap ==="
echo "Deploying OpenBao directly to ensure initialization before dependent apps"

# Create cf-openbao namespace
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# Deploy OpenBao using dedicated values file (no yq extraction needed)
helm template --release-name openbao ${SOURCE_ROOT}/sources/openbao/${OPENBAO_VERSION} --namespace cf-openbao \
  -f ${SOURCE_ROOT}/root/values_openbao.yaml \
  --set ui.enabled=true \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -

# Wait for OpenBao pod to be running
echo "⏳ Waiting for OpenBao pod to be ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

# Deploy OpenBao initialization job directly (critical for bootstrap)
echo "🔐 Deploying OpenBao initialization job..."
helm template --release-name openbao-init ${SOURCE_ROOT}/scripts/init-openbao-job \
  -f ${SOURCE_ROOT}/root/values_openbao.yaml \
  --set domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -

# Wait for initialization to complete
echo "⏳ Waiting for OpenBao initialization to complete..."
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Deploy OpenBao configuration (CronJobs) directly after initialization
echo "🔧 Deploying OpenBao configuration (CronJobs for ongoing management)..."

# Deploy the entire openbao-config chart efficiently
helm template --release-name openbao-config "${SOURCE_ROOT}/sources/openbao-config/0.1.0" \
    --namespace cf-openbao \
    --set domain="${DOMAIN}" \
    --kube-version="${KUBE_VERSION}" | kubectl apply -f -

echo "✅ OpenBao deployed, initialized, and configured directly"
echo ""
echo "=== Gitea Bootstrap ==="
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create gitea admin credentials secret
kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password) \
  --dry-run=client -o yaml | kubectl apply -f -

# Create initial-cf-values configmap with basic values for gitea-init-job
# Use simple shell variables instead of merged YAML
cat > /tmp/simple_values.yaml << EOF
global:
  domain: ${DOMAIN}
  clusterSize: values_${CLUSTER_SIZE}.yaml
clusterForge:
  targetRevision: ${TARGET_REVISION}
EOF

kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$(cat /tmp/simple_values.yaml)" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

# Bootstrap Gitea using dedicated values file (no yq extraction needed)
helm template --release-name gitea ${SOURCE_ROOT}/sources/gitea/${GITEA_VERSION} --namespace cf-gitea \
  -f ${SOURCE_ROOT}/root/values_gitea.yaml \
  --set clusterDomain="${DOMAIN}" \
  --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea

# Gitea Init Job
helm template --release-name gitea-init ${SOURCE_ROOT}/scripts/init-gitea-job \
  --set clusterSize="${SIZE_VALUES_FILE:-values_${CLUSTER_SIZE}.yaml}" \
  --set domain="${DOMAIN}" \
  --set targetRevision="${TARGET_REVISION}" \
  --kube-version=${KUBE_VERSION} \
  | kubectl apply -f -

kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

echo ""
echo "=== Creating ClusterForge Parent App-of-Apps ==="
echo "Cluster size: $CLUSTER_SIZE"
echo "Target revision: $TARGET_REVISION"

# Create minimal values for rendering only the cluster-forge parent app
cat > /tmp/cluster_forge_values.yaml <<EOF
# Minimal values for cluster-forge parent app rendering
externalValues:
  enabled: true
  path: ${VALUES_FILE}
  repoUrl: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git
  targetRevision: main

clusterForge:
  repoUrl: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git
  targetRevision: ${TARGET_REVISION}
  valuesFile: ${VALUES_FILE}

global:
  domain: ${DOMAIN}
  clusterSize: values_${CLUSTER_SIZE}.yaml
EOF

echo "🎯 Rendering cluster-forge parent app using template..."

# Render only the cluster-forge template (parent app-of-apps)
helm template cluster-forge "${SOURCE_ROOT}/root" \
    --show-only templates/cluster-forge.yaml \
    --values /tmp/cluster_forge_values.yaml \
    --namespace argocd \
    --kube-version "$KUBE_VERSION" | kubectl apply -f -

echo "✅ cluster-forge parent app applied!"
echo "🚀 ArgoCD will now manage all applications from target revision: $TARGET_REVISION"

# Cleanup temp file
rm -f /tmp/cluster_forge_values.yaml

cat <<__SUMMARY__

=== ClusterForge Bootstrap Complete ===

Domain: $DOMAIN
Cluster size: $CLUSTER_SIZE
Target revision: $TARGET_REVISION

🌐 Access URLs:
  ArgoCD:  https://argocd.${DOMAIN}
  OpenBao: https://openbao.${DOMAIN}
  Gitea:   https://gitea.${DOMAIN}

📋 What happens now:
  1. ✅ ArgoCD is running and managing the cluster  
  2. ✅ OpenBao provides secrets management and is fully initialized
  3. ✅ Gitea provides git repositories for ArgoCD
  4. 🎯 cluster-forge app will sync from: $TARGET_REVISION
  5. 📦 ArgoCD will deploy remaining enabled apps from target revision
  6. ⚡ Sync waves ensure proper deployment order for remaining apps

📋 Next steps:
  1. Monitor ArgoCD applications: kubectl get apps -n argocd
  2. Check sync status: kubectl get apps -n argocd -o wide
  3. View ArgoCD UI for detailed deployment progress

This is the way! 🚀
__SUMMARY__

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f /tmp/simple_values.yaml /tmp/cluster_forge_values.yaml