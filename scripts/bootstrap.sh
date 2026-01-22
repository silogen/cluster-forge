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
echo "DEBUG: Creating namespaces..."
kubectl create ns argocd --dry-run=client -o yaml > /tmp/ns-argocd.yaml
kubectl apply -f /tmp/ns-argocd.yaml
kubectl create ns cf-gitea --dry-run=client -o yaml > /tmp/ns-gitea.yaml  
kubectl apply -f /tmp/ns-gitea.yaml
kubectl create ns cf-openbao --dry-run=client -o yaml > /tmp/ns-openbao.yaml
kubectl apply -f /tmp/ns-openbao.yaml
rm -f /tmp/ns-*.yaml
echo "DEBUG: Namespaces created successfully"

# Determine values file arguments for size-specific deployment
VALUES_ARGS="-f ${SCRIPT_DIR}/../root/${VALUES_FILE}"
SIZE_VALUES_FILE="${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml"

if [ -f "$SIZE_VALUES_FILE" ]; then
    VALUES_ARGS="$VALUES_ARGS -f $SIZE_VALUES_FILE"
    echo "   ✓ Using size-specific values: values_${CLUSTER_SIZE}.yaml"
else
    echo "   ⚠ Size-specific values not found: $SIZE_VALUES_FILE (using base values only)"
fi

echo "DEBUG: VALUES_ARGS = $VALUES_ARGS"
echo "DEBUG: About to start ArgoCD bootstrap section..."

# ArgoCD bootstrap
# Create a temporary merged values file for extracting valuesObject
TEMP_VALUES="/tmp/merged-values-$$.yaml"
echo "DEBUG: Merging values files..."
echo "  Base file: ${SCRIPT_DIR}/../root/values_cf.yaml"
echo "  Size file: ${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml"

if [ -f "${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml" ]; then
    echo "DEBUG: Size-specific file exists, merging..."
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' ${SCRIPT_DIR}/../root/values_cf.yaml ${SCRIPT_DIR}/../root/values_${CLUSTER_SIZE}.yaml > "$TEMP_VALUES" 2>/dev/null || \
        cp ${SCRIPT_DIR}/../root/values_cf.yaml "$TEMP_VALUES"
else
    echo "DEBUG: Size-specific file not found, using base only..."
    cp ${SCRIPT_DIR}/../root/values_cf.yaml "$TEMP_VALUES"
fi

echo "DEBUG: Merged values file created. Size:"
ls -la "$TEMP_VALUES"
echo "DEBUG: First 20 lines of merged values:"
head -20 "$TEMP_VALUES"

# Extract valuesObject directly to a temporary file for helm
ARGOCD_VALUES_FILE="/tmp/argocd-final-values-$$.yaml"
echo "DEBUG: Extracting ArgoCD valuesObject from merged values..."

# Check if the path exists first
ARGOCD_CHECK=$(yq eval '.apps.argocd' "$TEMP_VALUES")
if echo "$ARGOCD_CHECK" | grep -q "null"; then
    echo "DEBUG: ERROR - .apps.argocd is null in merged values!"
    echo "DEBUG: Available apps:"
    yq eval '.apps | keys' "$TEMP_VALUES"
else
    echo "DEBUG: .apps.argocd found, extracting valuesObject..."
    yq eval '.apps.argocd.valuesObject' "$TEMP_VALUES" > "$ARGOCD_VALUES_FILE" 2>/dev/null || \
        echo "{}" > "$ARGOCD_VALUES_FILE"
fi

echo "DEBUG: ArgoCD valuesObject file size:"
ls -la "$ARGOCD_VALUES_FILE"
echo "DEBUG: ArgoCD valuesObject content:"
cat "$ARGOCD_VALUES_FILE"
echo "DEBUG: End of ArgoCD valuesObject"

# Check if the content is valid YAML
echo "DEBUG: Checking if extracted content is valid YAML..."
if yq eval '.' "$ARGOCD_VALUES_FILE" >/dev/null 2>&1; then
    echo "DEBUG: Valid YAML"
else
    echo "DEBUG: INVALID YAML!"
fi

echo "DEBUG: Running helm template for ArgoCD..."
echo "DEBUG: Values file: $ARGOCD_VALUES_FILE"
echo "DEBUG: Helm command will be:"
echo "  helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \\"
echo "    --values \"$ARGOCD_VALUES_FILE\" \\"
echo "    --namespace argocd \\"
echo "    --set global.domain=\"https://argocd.${DOMAIN}\" --kube-version=${KUBE_VERSION}"

ARGOCD_MANIFEST=$(helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \
  --values "$ARGOCD_VALUES_FILE" \
  --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$ARGOCD_MANIFEST"
rm -f "$ARGOCD_VALUES_FILE"
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
# Extract valuesObject directly to a temporary file for helm
OPENBAO_VALUES_FILE="/tmp/openbao-final-values-$$.yaml"
yq eval '.apps.openbao.valuesObject' "$TEMP_VALUES" > "$OPENBAO_VALUES_FILE" 2>/dev/null || \
    echo "{}" > "$OPENBAO_VALUES_FILE"

OPENBAO_MANIFEST=$(helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
  --values "$OPENBAO_VALUES_FILE" \
  --namespace cf-openbao --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$OPENBAO_MANIFEST"
rm -f "$OPENBAO_VALUES_FILE"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
OPENBAO_INIT_MANIFEST=$(helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
kubectl apply -f - <<< "$OPENBAO_INIT_MANIFEST"
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Gitea bootstrap
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create initial-cf-values configmap with size-aware values
echo "📝 Creating cluster configuration with size: $CLUSTER_SIZE"

# Generate merged configuration for gitea configmap
# Generate merged configuration for gitea configmap  
TEMP_CLUSTER_FORGE="/tmp/cluster-forge-$$.yaml"
helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --set global.domain="placeholder.domain" --show-only templates/cluster-forge.yaml > "$TEMP_CLUSTER_FORGE"
VALUES=$(yq '.spec.sources[0].helm.valueFiles = ["$values/values.yaml"] | .spec.sources[0].helm.parameters[0].value = "'$DOMAIN'"' "$TEMP_CLUSTER_FORGE")
rm -f "$TEMP_CLUSTER_FORGE"
echo "$VALUES" | kubectl create configmap initial-cf-values --from-file=/dev/stdin --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password)
# Extract valuesObject directly to a temporary file for helm  
GITEA_VALUES_FILE="/tmp/gitea-final-values-$$.yaml"
yq eval '.apps.gitea.valuesObject' "$TEMP_VALUES" > "$GITEA_VALUES_FILE" 2>/dev/null || \
    echo "{}" > "$GITEA_VALUES_FILE"

GITEA_MANIFEST=$(helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
  --values "$GITEA_VALUES_FILE" \
  --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION})

kubectl apply -f - <<< "$GITEA_MANIFEST"
rm -f "$GITEA_VALUES_FILE"
rm -f "$TEMP_VALUES"
kubectl rollout status deploy/gitea -n cf-gitea
GITEA_INIT_MANIFEST=$(helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
kubectl apply -f - <<< "$GITEA_INIT_MANIFEST"
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps with size-aware configuration
echo "🎯 Deploying cluster-forge applications with $CLUSTER_SIZE configuration"
CF_MANIFEST=$(helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
kubectl apply -f - <<< "$CF_MANIFEST"

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
