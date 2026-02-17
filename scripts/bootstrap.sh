#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
TARGET_REVISION="v1.8.0"

CLUSTER_SIZE="medium"  # Default to medium
DOMAIN=""
KUBE_VERSION=1.33
VALUES_FILE="values.yaml"

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
      cat <<HELP_OUTPUT
      Usage: $0 [options] <domain> [values_file]

      Arguments:
        domain                      Required. Cluster domain (e.g., example.com)
        values_file                 Optional. Values .yaml file to use, default: root/values.yaml
      
      Options:
        -r, --target-revision       cluster-forge git revision to seed into cluster-values/values.yaml file 
                                    options: [tag|commit_hash|branch_name], default: main
        -s, --cluster-size          options: [small|medium|large], default: medium

      Examples:
        $0 $(my.ip.fi).nip.io
        $0 example.com values_custom.yaml --cluster-size=large
        $0 dev.example.com --cluster-size=small --target-revision=v1.8.0
        $0 dev.example.com -s=small -r=v1.8.0
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

# Check if size-specific values file exists (optional overlay)
SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
if [ ! -f "${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE}" ]; then
    echo "WARNING: Size-specific values file not found: ${SCRIPT_DIR}/../root/${SIZE_VALUES_FILE}"
    echo "Proceeding with base values file only: ${VALUES_FILE}"
    SIZE_VALUES_FILE=""
fi

get_target_revision() {
  if [ "$TARGET_REVISION" == ""]; then return 0; fi

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
}

pre_cleanup() {
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

    echo "Pre-cleanup complete"
    echo ""
}

get_target_revision

# Run pre-cleanup
pre_cleanup

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

# Create initial secrets config for init job (separate from ArgoCD-managed version)
echo "Creating initial OpenBao secrets configuration..."
cat ${SCRIPT_DIR}/../sources/openbao-config/0.1.0/templates/openbao-secret-manager-cm.yaml | \
  sed "s|name: openbao-secret-manager-scripts|name: openbao-secret-manager-scripts-init|g" | kubectl apply -f -

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

# Bootstrap Gitea
helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 --namespace cf-gitea \
  -f /tmp/gitea_values.yaml \
  -f /tmp/gitea_size_values.yaml \
  --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea

# Gitea Init Job
helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job \
  --set clusterSize="values_${CLUSTER_SIZE}.yaml" \
  --set domain="${DOMAIN}" \
  --set targetRevision="${TARGET_REVISION}" \
  --kube-version=${KUBE_VERSION} \
  | kubectl apply -f -

kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps with merged configuration
echo "Creating ClusterForge app-of-apps (size: $CLUSTER_SIZE)..."
helm template ${SCRIPT_DIR}/../root \
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