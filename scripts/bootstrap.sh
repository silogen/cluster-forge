#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
DOMAIN=""
VALUES_FILE="values_cf.yaml"
CLUSTER_SIZE="medium"  # Default to medium
KUBE_VERSION=1.33

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
    --help|-h)
      echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large]"
      echo ""
      echo "Arguments:"
      echo "  domain                  Required. Cluster domain (e.g., example.com)"
      echo "  values_file            Optional. Values file to use (default: values_cf.yaml)"
      echo "  --CLUSTER_SIZE         Optional. Cluster size (default: medium)"
      echo ""
      echo "Cluster sizes:"
      echo "  small     - Developer/single-user setups (1-5 users)"
      echo "  medium    - Team clusters (5-20 users) [DEFAULT]"
      echo "  large     - Production/enterprise scale (10s-100s users)"
      echo ""
      echo "Examples:"
      echo "  $0 example.com"
      echo "  $0 example.com values_prod.yaml"
      echo "  $0 example.com values_cf.yaml --CLUSTER_SIZE=large"
      echo "  $0 dev.example.com --CLUSTER_SIZE=small"
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
      elif [ "$VALUES_FILE" = "values_cf.yaml" ]; then
        VALUES_FILE="$1"
      else
        echo "ERROR: Too many arguments: $1"
        echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large]"
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

# Function to merge values files early for use throughout the script
merge_values_files() {
    echo "Merging values files..."
    if [ -n "$SIZE_VALUES_FILE" ]; then
        # Merge base values with size-specific overrides
        VALUES=$($YQ_CMD eval-all '. as $item ireduce ({}; . * $item)' \
            ${SCRIPT_DIR}/../root/${VALUES_FILE} \
            ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE} | \
            $YQ_CMD eval ".global.domain = \"${DOMAIN}\"")
    else
        # Use base values only
        VALUES=$(cat ${SCRIPT_DIR}/../root/${VALUES_FILE} | $YQ_CMD ".global.domain = \"${DOMAIN}\"")
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
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD bootstrap
echo "Bootstrapping ArgoCD..."
# Extract ArgoCD values from merged config and write to temp values file
$YQ_CMD eval '.apps.argocd.valuesObject' /tmp/merged_values.yaml > /tmp/argocd_values.yaml

# Use server-side apply to match ArgoCD's self-management strategy
helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 --namespace argocd \
  -f /tmp/argocd_values.yaml \
  --set global.domain="https://argocd.${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
echo "Bootstrapping OpenBao..."
# Extract OpenBao values from merged config
$YQ_CMD eval '.apps.openbao.valuesObject' /tmp/merged_values.yaml > /tmp/openbao_values.yaml

# Use server-side apply to match ArgoCD's field management strategy
helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 --namespace cf-openbao \
  -f /tmp/openbao_values.yaml \
  --set ui.enabled=true \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s

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

helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" \
  --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" \
  --set gitea.config.database.DB_TYPE="sqlite3" \
  --set gitea.config.session.PROVIDER="memory" \
  --set gitea.config.cache.ADAPTER="memory" \
  --set gitea.config.queue.TYPE="level" \
  --set gitea.admin.existingSecret="gitea-admin-credentials" \
  --set strategy.type="Recreate" \
  --set valkey-cluster.enabled=false \
  --set valkey.enabled=false \
  --set postgresql.enabled=false \
  --set postgresql-ha.enabled=false \
  --set persistence.enabled=true \
  --set test.enabled=false \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
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
echo "Access ArgoCD at: https://argocd.${DOMAIN}"
echo "Access Gitea at: https://gitea.${DOMAIN}"
echo ""
echo "This is the way!"

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f /tmp/merged_values.yaml /tmp/argocd_values.yaml /tmp/openbao_values.yaml