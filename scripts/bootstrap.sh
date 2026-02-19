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
        -r, --target-revision       cluster-forge git revision to seed into cluster-values/values.yaml file 
                                    options: [tag|commit_hash|branch_name], default: $LATEST_RELEASE
        -s, --cluster-size          options: [small|medium|large], default: medium

      Examples:
        $0 compute.amd.com values_custom.yaml --cluster-size=large
        $0 112.100.97.17.nip.io
        $0 dev.example.com --cluster-size=small --target-revision=$LATEST_RELEASE
        $0 dev.example.com -s=small -r=$LATEST_RELEASE
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

validate_target_revision() {
    # Always allow main and the latest release
    if [ "$TARGET_REVISION" = "main" ] || [ "$TARGET_REVISION" = "$LATEST_RELEASE" ]; then
        return 0
    fi
    
    # Check if it's a valid v1.8.0+ semantic version pattern
    if [[ "$TARGET_REVISION" =~ ^v1\.8\. ]] || [[ "$TARGET_REVISION" =~ ^v1\.([9-9]|[1-9][0-9]+)\. ]] || [[ "$TARGET_REVISION" =~ ^v[2-9]\. ]]; then
        return 0
    fi
    
    # For branches/commits, check git ancestry to see if v1.8.0-rc1 or later is in the history
    echo "Checking git ancestry for target revision: $TARGET_REVISION"
    
    # Check if the target revision exists in git (try local first, then remote)
    RESOLVED_REVISION=""
    if git rev-parse --verify "$TARGET_REVISION" >/dev/null 2>&1; then
        RESOLVED_REVISION="$TARGET_REVISION"
    elif git rev-parse --verify "origin/$TARGET_REVISION" >/dev/null 2>&1; then
        RESOLVED_REVISION="origin/$TARGET_REVISION"
        echo "Found target revision as remote branch: origin/$TARGET_REVISION"
    else
        echo "ERROR: Target revision '$TARGET_REVISION' does not exist in git"
        echo "Available branches: $(git branch -a | grep -v HEAD | sed 's/^[ *]*//' | tr '\n' ' ')"
        exit 1
    fi
    
    # Check if v1.8.0-rc1 or any later version is an ancestor of the target revision
    # We'll check for v1.8.0-rc1 as the minimum supported version
    MIN_SUPPORTED_TAG="v1.8.0-rc1"
    
    # Check if the minimum supported tag exists
    if git rev-parse --verify "$MIN_SUPPORTED_TAG" >/dev/null 2>&1; then
        # Check if MIN_SUPPORTED_TAG is an ancestor of RESOLVED_REVISION
        if git merge-base --is-ancestor "$MIN_SUPPORTED_TAG" "$RESOLVED_REVISION" 2>/dev/null; then
            echo "Target revision '$TARGET_REVISION' is based on or after $MIN_SUPPORTED_TAG - supported"
            return 0
        else
            echo "ERROR: Target revision '$TARGET_REVISION' is not based on $MIN_SUPPORTED_TAG or later"
            echo "The --target-revision flag only supports revisions based on $MIN_SUPPORTED_TAG and later versions"
            echo "Supported: v1.8.0+, main, branches forked from v1.8.0-rc1+, or $LATEST_RELEASE"
            exit 1
        fi
    else
        echo "WARNING: Minimum supported tag '$MIN_SUPPORTED_TAG' not found in git"
        echo "Proceeding with target revision '$TARGET_REVISION' (ancestry check skipped)"
        return 0
    fi
}

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

# Validate target revision and setup sources
validate_target_revision
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
echo "⚠️  This will bootstrap ClusterForge on your cluster with the above configuration."
echo "   Existing ArgoCD, OpenBao, and Gitea resources may be modified or replaced."
echo ""
read -p "Continue with bootstrap? [Y/n]: " -r
echo ""
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Bootstrap cancelled by user."
    exit 0
fi
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
    OPENBAO_VERSION=$($YQ_CMD eval '.apps.openbao.path' /tmp/merged_values.yaml | cut -d'/' -f2) 
    GITEA_VERSION=$($YQ_CMD eval '.apps.gitea.path' /tmp/merged_values.yaml | cut -d'/' -f2)
    
    echo "Extracted versions - ArgoCD: $ARGOCD_VERSION, OpenBao: $OPENBAO_VERSION, Gitea: $GITEA_VERSION"
}

# Merge values files early so all subsequent operations can use the merged config
merge_values_files

# Extract version information from merged values
extract_app_versions

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

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
echo "=== OpenBao Bootstrap ==="
# Extract OpenBao values from merged config
$YQ_CMD eval '.apps.openbao.valuesObject' ${SOURCE_ROOT}/root/${VALUES_FILE} > /tmp/openbao_values.yaml
$YQ_CMD eval '.apps.openbao.valuesObject' ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}  > /tmp/openbao_size_values.yaml
# Use server-side apply to match ArgoCD's field management strategy
helm template --release-name openbao ${SOURCE_ROOT}/sources/openbao/${OPENBAO_VERSION} --namespace cf-openbao \
  -f /tmp/openbao_values.yaml \
  -f /tmp/openbao_size_values.yaml \
  --set ui.enabled=true \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s

# Create initial secrets config for init job (separate from ArgoCD-managed version)
echo "Creating initial OpenBao secrets configuration..."
cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-manager-cm.yaml | \
  sed "s|name: openbao-secret-manager-scripts|name: openbao-secret-manager-scripts-init|g" | kubectl apply -f -

# Create initial secrets config for init job (separate from ArgoCD-managed version)
echo "Creating initial OpenBao secrets configuration..."
cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | \
  sed "s|{{ .Values.domain }}|${DOMAIN}|g" | \
  sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -

# Pass OpenBao configuration to init script
helm template --release-name openbao-init ${SOURCE_ROOT}/scripts/init-openbao-job \
  -f /tmp/openbao_values.yaml \
  --set domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

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
echo "=== Creating ClusterForge App-of-Apps ==="
echo "Cluster size: $CLUSTER_SIZE"
helm template ${SOURCE_ROOT}/root \
    -f /tmp/merged_values.yaml \
    --kube-version=${KUBE_VERSION} | kubectl apply -f -

echo <<__SUMMARY__

  === ClusterForge Bootstrap Complete ==="
  
  Domain: $DOMAIN
  Cluster size: $CLUSTER_SIZE
  Target revision: $TARGET_REVISION
  
  Access ArgoCD at: https://argocd.${DOMAIN}
  Access Gitea at: https://gitea.${DOMAIN}

  This is the way!
__SUMMARY__

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f /tmp/merged_values.yaml /tmp/argocd_values.yaml /tmp/openbao_values.yaml