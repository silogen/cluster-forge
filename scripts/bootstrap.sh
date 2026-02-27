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
        • Bootstrap deploys ArgoCD + Gitea directly (essential infrastructure)
        • cluster-forge parent app then deployed to manage remaining apps  
        • ArgoCD syncs ALL apps from specified target revision
        • OpenBao and other apps deploy via ArgoCD (not directly)
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
pre_cleanup

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

# Check for yq command availability
if command -v yq >/dev/null 2>&1; then
    YQ_CMD="yq"
elif [ -f "$HOME/yq" ]; then
    YQ_CMD="$HOME/yq"
else
    echo "ERROR: yq command not found. Please install yq or place it in $HOME/yq"
    exit 1
fi

# Update the global.clusterSize in the base values file with mapped filename
if [ -n "$SIZE_VALUES_FILE" ]; then
    $YQ_CMD -i ".global.clusterSize = \"${SIZE_VALUES_FILE}\"" "${SOURCE_ROOT}/root/${VALUES_FILE}"
else
    $YQ_CMD -i ".global.clusterSize = \"values_${CLUSTER_SIZE}.yaml\"" "${SOURCE_ROOT}/root/${VALUES_FILE}"
fi

# Note: clusterForge.targetRevision will be set by the gitea-init-job
# in the cluster-values repository (which overwrites the base values as the final values file)
echo "Target revision $TARGET_REVISION will be set in cluster-values repo by gitea-init-job"

# Function to merge values files early for use throughout the script
merge_values_files() {
    echo "Merging values files..."
    if [ -n "$SIZE_VALUES_FILE" ]; then
        # Merge base values with size-specific overrides
        VALUES=$($YQ_CMD eval-all '. as $item ireduce ({}; . * $item)' \
            ${SOURCE_ROOT}/root/${VALUES_FILE} \
            ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE} | \
            $YQ_CMD eval ".global.domain = \"${DOMAIN}\"")
    else
        # Use base values only
        VALUES=$(cat ${SOURCE_ROOT}/root/${VALUES_FILE} | $YQ_CMD ".global.domain = \"${DOMAIN}\"")
    fi
    
    # Apply the target revision override (matching what cluster-values repo will contain)
    echo "Applying targetRevision override: $TARGET_REVISION"
    VALUES=$(echo "$VALUES" | $YQ_CMD eval ".clusterForge.targetRevision = \"${TARGET_REVISION}\"")
    
    # Write merged values to temp file for use throughout script
    echo "$VALUES" > /tmp/merged_values.yaml
    echo "Merged values written to /tmp/merged_values.yaml"
}

# Helper functions to extract values from merged configuration
get_argocd_value() {
    local path="$1"
    $YQ_CMD eval ".apps.argocd.valuesObject.${path}" /tmp/merged_values.yaml
}

get_openbao_value() {
    local path="$1"  
    $YQ_CMD eval ".apps.openbao.valuesObject.${path}" /tmp/merged_values.yaml
}

# Extract version information from app paths
extract_app_versions() {
    ARGOCD_VERSION=$($YQ_CMD eval '.apps.argocd.path' /tmp/merged_values.yaml | cut -d'/' -f2)
    GITEA_VERSION=$($YQ_CMD eval '.apps.gitea.path' /tmp/merged_values.yaml | cut -d'/' -f2)
    
    echo "Extracted versions - ArgoCD: $ARGOCD_VERSION, Gitea: $GITEA_VERSION"
}

# Merge values files early so all subsequent operations can use the merged config
merge_values_files

# Extract version information from merged values
extract_app_versions

# Create namespaces for direct deployments only
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
# Note: cf-openbao namespace will be created by ArgoCD when it deploys OpenBao

echo ""
echo "=== ArgoCD Bootstrap ==="
# Extract ArgoCD values from merged config and write to temp values file
$YQ_CMD eval '.apps.argocd.valuesObject' ${SOURCE_ROOT}/root/${VALUES_FILE} > /tmp/argocd_values.yaml
$YQ_CMD eval '.apps.argocd.valuesObject' ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE} > /tmp/argocd_size_values.yaml
# Use server-side apply to match ArgoCD's self-management strategy
helm template --release-name argocd ${SOURCE_ROOT}/sources/argocd/${ARGOCD_VERSION} --namespace argocd \
  -f /tmp/argocd_values.yaml \
  -f /tmp/argocd_size_values.yaml \
  --set global.domain="argocd.${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

echo ""
echo "=== Skipping OpenBao Direct Deployment ==="
echo "OpenBao will be deployed via ArgoCD after cluster-forge parent app is applied"
echo ""
echo "=== Gitea Bootstrap ==="
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create initial-cf-values configmap with merged values
echo "Creating initial-cf-values configmap from merged configuration..."
kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$(cat /tmp/merged_values.yaml)" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password) \
  --dry-run=client -o yaml | kubectl apply -f -

$YQ_CMD eval '.apps.gitea.valuesObject' ${SOURCE_ROOT}/root/${VALUES_FILE} > /tmp/gitea_values.yaml
$YQ_CMD eval '.apps.gitea.valuesObject' ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE} > /tmp/gitea_size_values.yaml

# Bootstrap Gitea
helm template --release-name gitea ${SOURCE_ROOT}/sources/gitea/${GITEA_VERSION} --namespace cf-gitea \
  -f /tmp/gitea_values.yaml \
  -f /tmp/gitea_size_values.yaml \
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
  Gitea:   https://gitea.${DOMAIN}

📋 What happens now:
  1. ✅ ArgoCD is running and managing the cluster
  2. ✅ Gitea provides git repositories for ArgoCD
  3. 🎯 cluster-forge app will sync from: $TARGET_REVISION
  4. 📦 ArgoCD will deploy ALL enabled apps from target revision
  5. 🔄 OpenBao and other apps deploy via ArgoCD (not directly)
  6. ⚡ Sync waves ensure proper deployment order

📋 Next steps:
  1. Monitor ArgoCD applications: kubectl get apps -n argocd
  2. Check sync status: kubectl get apps -n argocd -o wide
  3. View ArgoCD UI for detailed deployment progress

This is the way! 🚀
__SUMMARY__

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f /tmp/merged_values.yaml /tmp/argocd_values.yaml