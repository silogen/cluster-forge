#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
DOMAIN=""
VALUES_FILE="values.yaml"
CLUSTER_SIZE="medium"  # Default to medium
KUBE_VERSION=1.33
DEV_MODE=false
TARGET_REVISION="main" # default unless in --dev mode

# Parse arguments 
while [[ $# -gt 0 ]]; do
  case $1 in
    --CLUSTER_SIZE)
      if [ -z "$2" ]; then
        echo "ERROR: --CLUSTER_SIZE requires an argument"
        exit 1
      fi
      CLUSTER_SIZE="$2"
      shift 2
      ;;
    --CLUSTER_SIZE=*)
      CLUSTER_SIZE="${1#*=}"
      shift
      ;;
    --dev)
      DEV_MODE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [domain] [values_file] [--CLUSTER_SIZE=small|medium|large] [--dev]"
      echo ""
      echo "Arguments:"
      echo "  domain                  Required. Cluster domain (e.g., example.com)"
      echo "  values_file            Optional. Values file to use (default: values.yaml)"
      echo "  --CLUSTER_SIZE         Optional. Cluster size (default: medium)"
      echo "  --dev                  Optional. Development mode - skips Gitea, points to GitHub"
      echo ""
      echo "Cluster sizes:"
      echo "  small     - Developer/single-user setups (1-5 users)"
      echo "  medium    - Team clusters (5-20 users) [DEFAULT]"
      echo "  large     - Production/enterprise scale (10s-100s users)"
      echo ""
      echo "Examples:"
      echo "  $0 example.com"
      echo "  $0 example.com values.yaml --CLUSTER_SIZE=large"
      echo "  $0 dev.example.com --CLUSTER_SIZE=small"
      echo "  $0 --dev                    # Uses domain from configmap"
      echo "  $0 example.com --dev        # Dev mode with custom domain"
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
        echo "Usage: $0 [domain] [values_file] [--CLUSTER_SIZE=small|medium|large] [--dev]"
        exit 1
      fi
      shift
      ;;
  esac
done

# Function to get domain from configmap or validate provided domain
get_domain() {
    if [ -z "$DOMAIN" ]; then
        echo "No domain provided, attempting to read from bloom-config configmap..."
        if kubectl get configmap bloom-config -n default >/dev/null 2>&1; then
            DOMAIN=$(kubectl get configmap bloom-config -n default -o jsonpath='{.data.domain}' 2>/dev/null)
            if [ -n "$DOMAIN" ]; then
                echo "Domain read from configmap: $DOMAIN"
            else
                echo "ERROR: Domain key not found in bloom-config configmap"
                echo "Please provide domain as argument or ensure bloom-config configmap exists with 'domain' key"
                exit 1
            fi
        else
            echo "ERROR: bloom-config configmap not found in default namespace"
            echo "Please provide domain as argument or create bloom-config configmap with 'domain' key"
            exit 1
        fi
    fi
}

# Function to get git branch and prompt for target revision in dev mode
get_target_revision() {
    if [ "$DEV_MODE" = true ]; then
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        echo ""
        echo "Development mode enabled - ArgoCD will point to live GitHub repository"
        echo "Current git branch: $CURRENT_BRANCH"
        echo ""
        read -p "Use current branch '$CURRENT_BRANCH' for targetRevision? [Y/n/custom_branch]: " choice
        
        case "$choice" in
            n|N|no|No|NO)
                echo "Exiting. Please checkout the branch you want to use and run again."
                exit 0
                ;;
            [Cc]ustom*|custom*)
                read -p "Enter custom branch name: " custom_branch
                if [ -n "$custom_branch" ]; then
                    TARGET_REVISION="$custom_branch"
                else
                    echo "ERROR: Custom branch name cannot be empty"
                    exit 1
                fi
                ;;
            y|Y|yes|Yes|YES|"")
                TARGET_REVISION="$CURRENT_BRANCH"
                ;;
            *)
                # Treat any other input as a custom branch name
                TARGET_REVISION="$choice"
                ;;
        esac
        echo "Using targetRevision: $TARGET_REVISION"
    fi
}

# Validate domain
get_domain

# Handle dev mode branch selection
get_target_revision

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

# Check if size-specific values file exists (optional overlay)
SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
if [ ! -f "${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE}" ]; then
    echo "WARNING: Size-specific values file not found: ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE}"
    echo "Proceeding with base values file only: ${VALUES_FILE}"
    SIZE_VALUES_FILE=""
fi

echo "=== ClusterForge Bootstrap ==="
echo "Domain: $DOMAIN"
echo "Base values: $VALUES_FILE"
echo "Cluster size: $CLUSTER_SIZE"
if [ -n "$SIZE_VALUES_FILE" ]; then
    echo "Size overlay: $SIZE_VALUES_FILE"
fi
echo "============================"

# Check for yq command availability
if command -v yq >/dev/null 2>&1; then
    YQ_CMD="yq"
elif [ -f "$HOME/yq" ]; then
    YQ_CMD="$HOME/yq"
else
    echo "ERROR: yq command not found. Please install yq or place it in $HOME/yq"
    exit 1
fi

# Update the global.clusterSize in the base values file with full filename
$YQ_CMD -i ".global.clusterSize = \"values_${CLUSTER_SIZE}.yaml\"" "${SCRIPT_DIR}/../root/${VALUES_FILE}"

# Function to merge values files early for use throughout the script
merge_values_files() {
    echo "Merging values files..."  

    # Merge base values with size-specific overrides
    VALUES=$($YQ_CMD eval-all '. as $item ireduce ({}; . * $item)' \
        ${SCRIPT_DIR}/../root/${VALUES_FILE} \
        ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE} | \
        $YQ_CMD eval ".global.domain = \"${DOMAIN}\"")
    
    # In dev mode, update repository settings to point to GitHub
    if [ "$DEV_MODE" = true ]; then
        VALUES=$(echo "$VALUES" | $YQ_CMD eval "
            .spec.source.repoURL = \"https://github.com/your-org/your-repo\" |
            .spec.source.targetRevision = \"${TARGET_REVISION}\"
        ")
        echo "Updated repository settings for dev mode"
    fi
    
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

# Merge values files early so all subsequent operations can use the merged config
merge_values_files

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
if [ "$DEV_MODE" = false ]; then
    kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
fi
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD bootstrap
echo "Bootstrapping ArgoCD..."
# Extract ArgoCD values from merged config and write to temp values file
$YQ_CMD eval '.apps.argocd.valuesObject' ${SCRIPT_DIR}/../root/${VALUES_FILE} > /tmp/argocd_values.yaml
$YQ_CMD eval '.apps.argocd.valuesObject' ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE} > /tmp/argocd_size_values.yaml
# Use server-side apply to match ArgoCD's self-management strategy
helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 --namespace argocd \
  -f /tmp/argocd_values.yaml \
  -f /tmp/argocd_size_values.yaml \
  --set global.domain="argocd.${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
echo "Bootstrapping OpenBao..."
# Extract OpenBao values from merged config
$YQ_CMD eval '.apps.openbao.valuesObject' ${SCRIPT_DIR}/../root/${VALUES_FILE} > /tmp/openbao_values.yaml
$YQ_CMD eval '.apps.openbao.valuesObject' ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE}  > /tmp/openbao_size_values.yaml
# Use server-side apply to match ArgoCD's field management strategy
helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 --namespace cf-openbao \
  -f /tmp/openbao_values.yaml \
  -f /tmp/openbao_size_values.yaml \
  --set ui.enabled=true \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s

# Create static ConfigMaps needed for init job
echo "Creating OpenBao config static resources..."
helm template --release-name openbao-config-static ${SCRIPT_DIR}/init-openbao-job \
  --set domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} \
  --show-only templates/openbao-secret-manager-cm.yaml | kubectl apply -f -

# Create initial secrets config for init job (separate from ArgoCD-managed version)
echo "Creating initial OpenBao secrets configuration..."
cat ${SCRIPT_DIR}/../sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | \
  sed "s|{{ .Values.domain }}|${DOMAIN}|g" | \
  sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -

# Pass OpenBao configuration to init script
helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job \
  -f /tmp/openbao_values.yaml \
  --set domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Gitea bootstrap
echo "Bootstrapping Gitea..."
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

$YQ_CMD eval '.apps.gitea.valuesObject' ${SCRIPT_DIR}/../root/${VALUES_FILE} > /tmp/gitea_values.yaml
$YQ_CMD eval '.apps.gitea.valuesObject' ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE} > /tmp/gitea_size_values.yaml

helm template \
    --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
    --namespace cf-gitea \
    --file /tmp/gitea_values.yaml \
    --file /tmp/gitea_size_values.yaml \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
    --kube-version=${KUBE_VERSION} \
    | kubectl apply -f -

kubectl rollout status deploy/gitea -n cf-gitea
# Run Gitea init job
helm template \
    --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job \
    --set domain="${DOMAIN}" \
    --set clusterSize="values_${CLUSTER_SIZE}.yaml" \
    --set targetRevision="${TARGET_REVISION}"
    --kube-version=${KUBE_VERSION} \
    | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps with merged configuration
echo "Creating ClusterForge app-of-apps (size: $CLUSTER_SIZE)..."
helm template ${SCRIPT_DIR}/../root \
    -f /tmp/merged_values.yaml \
    --kube-version=${KUBE_VERSION} | kubectl apply -f -

echo ""
echo "=== ClusterForge Bootstrap Complete ==="
echo "Domain: $DOMAIN"
echo "Cluster size: $CLUSTER_SIZE"
if [ "$DEV_MODE" = true ]; then
    echo "Mode: Development (GitHub integration)"
    echo "Target revision: $TARGET_REVISION"
    echo "Access ArgoCD at: https://argocd.${DOMAIN}"
    echo "NOTE: Gitea was skipped in development mode"
else
    echo "Mode: Production (Gitea integration)"
    echo "Access ArgoCD at: https://argocd.${DOMAIN}"
    echo "Access Gitea at: https://gitea.${DOMAIN}"
fi
echo ""
echo "This is the way!"

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f /tmp/merged_values.yaml /tmp/argocd_values.yaml /tmp/openbao_values.yaml