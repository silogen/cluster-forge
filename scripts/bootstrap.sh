#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure yq is available 
if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: yq is required but not found. Please install yq:"
    echo "  curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq"
    echo "  chmod +x /usr/local/bin/yq"
    exit 1
fi

# Initialize variables
DOMAIN="${1:-}"
CLUSTER_SIZE=""
VALUES_FILE="${2:-values_cf.yaml}"  # Maintain backwards compatibility
KUBE_VERSION=1.33

# Parse arguments - handle both old and new parameter styles
if [[ $# -ge 2 ]] && [[ "$2" =~ ^--SIZE= ]]; then
    # New style: bootstrap.sh domain --SIZE=medium
    CLUSTER_SIZE=$(echo "$2" | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
    VALUES_FILE="values_cf.yaml"  # Use default when SIZE is specified
elif [[ $# -ge 3 ]] && [[ "$3" =~ ^--SIZE= ]]; then
    # Mixed style: bootstrap.sh domain values_file --SIZE=medium  
    VALUES_FILE="$2"
    CLUSTER_SIZE=$(echo "$3" | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
fi

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file] [--SIZE=s|small|m|medium|l|large]"
    echo "   or: $0 <domain> [--SIZE=s|small|m|medium|l|large]"
    echo ""
    echo "Examples:"
    echo "  $0 example.com                    # Uses default size (medium)"
    echo "  $0 example.com --SIZE=small       # Uses small size"
    echo "  $0 example.com --SIZE=l           # Uses large size"
    echo "  $0 example.com custom.yaml --SIZE=medium  # Custom values + medium size"
    exit 1
fi

# Normalize and validate cluster size
if [ -n "$CLUSTER_SIZE" ]; then
    case "$CLUSTER_SIZE" in
        s|small)
            CLUSTER_SIZE="small"
            ;;
        m|medium)
            CLUSTER_SIZE="medium"
            ;;
        l|large)
            CLUSTER_SIZE="large"
            ;;
        *)
            echo "ERROR: Invalid cluster size '$CLUSTER_SIZE'. Valid options: s, small, m, medium, l, large"
            exit 1
            ;;
    esac
else
    CLUSTER_SIZE="medium"  # Default to medium if not specified
fi

echo "🚀 Cluster-Forge Bootstrap Configuration:"
echo "   Domain: $DOMAIN"
echo "   Size: $CLUSTER_SIZE"
echo "   Values: $VALUES_FILE"
echo ""

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# Determine values file arguments for size-specific deployment
VALUES_ARGS="-f ${SCRIPT_DIR}/../root/${VALUES_FILE}"
SIZE_VALUES_FILE="${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml"

if [ -f "$SIZE_VALUES_FILE" ]; then
    VALUES_ARGS="$VALUES_ARGS -f $SIZE_VALUES_FILE"
    echo "   ✓ Using size-specific values: values_${CLUSTER_SIZE}.yaml"
else
    echo "   ⚠ Size-specific values not found: $SIZE_VALUES_FILE (using base values only)"
fi

# ArgoCD bootstrap
# Create temporary merged values file for ArgoCD
ARGOCD_MERGED_CONFIG="/tmp/bootstrap-argocd-$$.yaml"
echo "apps:" > "$ARGOCD_MERGED_CONFIG"
echo "  argocd:" >> "$ARGOCD_MERGED_CONFIG" 
echo "    valuesObject: {}" >> "$ARGOCD_MERGED_CONFIG"

# Merge valuesObject from values files with size overrides
# Create a temporary merged values file for extracting valuesObject
TEMP_VALUES="/tmp/merged-values-$$.yaml"
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' ${SCRIPT_DIR}/../root/values_cf.yaml ${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml > "$TEMP_VALUES" 2>/dev/null || \
    cp ${SCRIPT_DIR}/../root/values_cf.yaml "$TEMP_VALUES"
yq eval '.apps.argocd.valuesObject' "$TEMP_VALUES" > /tmp/argocd-values-$$.yaml 2>/dev/null || \
    echo "{}" > /tmp/argocd-values-$$.yaml

yq eval '.apps.argocd.valuesObject = load("/tmp/argocd-values-'$$'.yaml")' "$ARGOCD_MERGED_CONFIG" > "${ARGOCD_MERGED_CONFIG}.tmp"
mv "${ARGOCD_MERGED_CONFIG}.tmp" "$ARGOCD_MERGED_CONFIG"
rm -f /tmp/argocd-values-$$.yaml

# Extract valuesObject to a temporary file for helm
ARGOCD_VALUES_FILE="/tmp/argocd-final-values-$$.yaml"
yq '.apps.argocd.valuesObject' "$ARGOCD_MERGED_CONFIG" > "$ARGOCD_VALUES_FILE"

ARGOCD_MANIFEST=$(helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \
  --values "$ARGOCD_VALUES_FILE" \
  --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$ARGOCD_MANIFEST"
rm -f "$ARGOCD_MERGED_CONFIG"
rm -f "$ARGOCD_VALUES_FILE"
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
# Create temporary merged values file for OpenBao
OPENBAO_MERGED_CONFIG="/tmp/bootstrap-openbao-$$.yaml"
echo "apps:" > "$OPENBAO_MERGED_CONFIG"
echo "  openbao:" >> "$OPENBAO_MERGED_CONFIG"
echo "    valuesObject: {}" >> "$OPENBAO_MERGED_CONFIG"

# Merge valuesObject from values files with size overrides
yq eval '.apps.openbao.valuesObject' "$TEMP_VALUES" > /tmp/openbao-values-$$.yaml 2>/dev/null || \
    echo "{}" > /tmp/openbao-values-$$.yaml

yq eval '.apps.openbao.valuesObject = load("/tmp/openbao-values-'$$'.yaml")' "$OPENBAO_MERGED_CONFIG" > "${OPENBAO_MERGED_CONFIG}.tmp"
mv "${OPENBAO_MERGED_CONFIG}.tmp" "$OPENBAO_MERGED_CONFIG"
rm -f /tmp/openbao-values-$$.yaml

# Extract valuesObject to a temporary file for helm
OPENBAO_VALUES_FILE="/tmp/openbao-final-values-$$.yaml"
yq '.apps.openbao.valuesObject' "$OPENBAO_MERGED_CONFIG" > "$OPENBAO_VALUES_FILE"

OPENBAO_MANIFEST=$(helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
  --values "$OPENBAO_VALUES_FILE" \
  --namespace cf-openbao --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$OPENBAO_MANIFEST"
rm -f "$OPENBAO_MERGED_CONFIG"
rm -f "$OPENBAO_VALUES_FILE"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Gitea bootstrap
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create initial-cf-values configmap with size-aware values
echo "📝 Creating cluster configuration with size: $CLUSTER_SIZE"

# Generate merged configuration for gitea configmap
eval "VALUES=\$(helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --set global.domain=\"placeholder.domain\" --show-only templates/cluster-forge.yaml | yq '.spec.sources[0].helm.valueFiles = [\"\$values/values.yaml\"] | .spec.sources[0].helm.parameters[0].value = \"'$DOMAIN'\"')"
kubectl create configmap initial-cf-values --from-file=/dev/stdin --dry-run=client -o yaml <<< "$VALUES" | kubectl apply -n cf-gitea -f -

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password)
# Create temporary merged values file for Gitea  
GITEA_MERGED_CONFIG="/tmp/bootstrap-gitea-$$.yaml"
echo "apps:" > "$GITEA_MERGED_CONFIG"
echo "  gitea:" >> "$GITEA_MERGED_CONFIG"
echo "    valuesObject: {}" >> "$GITEA_MERGED_CONFIG"

# Merge valuesObject from values files with size overrides
yq eval '.apps.gitea.valuesObject' "$TEMP_VALUES" > /tmp/gitea-values-$$.yaml 2>/dev/null || \
    echo "{}" > /tmp/gitea-values-$$.yaml

yq eval '.apps.gitea.valuesObject = load("/tmp/gitea-values-'$$'.yaml")' "$GITEA_MERGED_CONFIG" > "${GITEA_MERGED_CONFIG}.tmp"
mv "${GITEA_MERGED_CONFIG}.tmp" "$GITEA_MERGED_CONFIG"
rm -f /tmp/gitea-values-$$.yaml

# Extract valuesObject to a temporary file for helm
GITEA_VALUES_FILE="/tmp/gitea-final-values-$$.yaml"
yq '.apps.gitea.valuesObject' "$GITEA_MERGED_CONFIG" > "$GITEA_VALUES_FILE"

GITEA_MANIFEST=$(helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
  --values "$GITEA_VALUES_FILE" \
  --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$GITEA_MANIFEST"
rm -f "$GITEA_MERGED_CONFIG"
rm -f "$GITEA_VALUES_FILE"
rm -f "$TEMP_VALUES"
kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps with size-aware configuration
echo "🎯 Deploying cluster-forge applications with $CLUSTER_SIZE configuration"
eval "helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --set global.domain=\"${DOMAIN}\" --kube-version=${KUBE_VERSION} | kubectl apply -f -"

echo ""
echo "✅ Cluster-Forge bootstrap complete! This is the way!"
echo ""
echo "🌐 Access your services:"
echo "   ArgoCD:  https://argocd.${DOMAIN}"
echo "   Gitea:   https://gitea.${DOMAIN}"
echo "   OpenBao: https://openbao.${DOMAIN}"
echo ""
echo "🔑 To access credentials, use these kubectl commands:"
echo "   # ArgoCD admin password:"
echo "   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""  
echo "   # Gitea admin credentials:"
echo "   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath='{.data.username}' | base64 -d"
echo "   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "   # OpenBao root token:"
echo "   kubectl -n cf-openbao get secret openbao-init-secret -o jsonpath='{.data.root_token}' | base64 -d"
echo ""
echo "📊 Cluster Configuration:"
echo "   Size: ${CLUSTER_SIZE}"
echo "   Domain: ${DOMAIN}"
echo "   Values: ${VALUES_FILE}"
if [ -f "$SIZE_VALUES_FILE" ]; then
    echo "   Size Overrides: values_${CLUSTER_SIZE}.yaml"
fi
