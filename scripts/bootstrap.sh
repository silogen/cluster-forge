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
        $0 dev.example.com --cluster-size=small --target-revision=v1.8.0
        $0 dev.example.com -s=small -r=feature-branch
        
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

SOURCE_ROOT="${SCRIPT_DIR}/.."
SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"

echo "=== ClusterForge Bootstrap ==="
echo "Domain: $DOMAIN"
echo "Base values: $VALUES_FILE"
echo "Cluster size: $CLUSTER_SIZE"
echo "Target revision: $TARGET_REVISION"

helm template cluster-forge "${SOURCE_ROOT}/root" \
    --show-only templates/cluster-forge.yaml \
    -f "${SOURCE_ROOT}/root/${VALUES_FILE}" \
    -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" \
    --set global.domain="${DOMAIN}" \
    --set clusterForge.targetRevision="${TARGET_REVISION}" \
    --set externalValues.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git" \
    --set clusterForge.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git" \
    --namespace argocd \
    --kube-version "${KUBE_VERSION}" | kubectl apply -f -
echo ""

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD bootstrap
echo "=== ArgoCD Bootstrap ==="
helm template --release-name argocd ${SOURCE_ROOT}/sources/argocd/8.3.5 --namespace argocd \
  -f ${SOURCE_ROOT}/root/values_argocd.yaml \
  --set global.domain="argocd.${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout=300s
kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s

# OpenBao bootstrap
echo "=== OpenBao Bootstrap ==="
helm template --release-name openbao ${SOURCE_ROOT}/sources/openbao/0.18.2 --namespace cf-openbao \
  -f ${SOURCE_ROOT}/root/values_openbao.yaml \
  --set ui.enabled=true \
  --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

helm template --release-name openbao-init ${SOURCE_ROOT}/scripts/init-openbao-job \
  -f ${SOURCE_ROOT}/root/values_openbao.yaml \
  --set domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Gitea bootstrap
echo "=== Gitea Bootstrap ==="
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create initial-cf-values configmap (simple values for gitea-init-job)
cat > /tmp/simple_values.yaml << EOF
global:
  domain: ${DOMAIN}
  clusterSize: ${SIZE_VALUES_FILE}
clusterForge:
  targetRevision: ${TARGET_REVISION}
EOF

kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$(cat /tmp/simple_values.yaml)" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password) \
  --dry-run=client -o yaml | kubectl apply -f -

helm template --release-name gitea ${SOURCE_ROOT}/sources/gitea/12.3.0 --namespace cf-gitea \
  -f ${SOURCE_ROOT}/root/values_gitea.yaml \
  --set clusterDomain="${DOMAIN}" \
  --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s

helm template --release-name gitea-init ${SOURCE_ROOT}/scripts/init-gitea-job \
  --set clusterSize="${SIZE_VALUES_FILE}" \
  --set domain="${DOMAIN}" \
  --set targetRevision="${TARGET_REVISION}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge parent app only (not all apps)
echo "=== Creating ClusterForge Parent App ==="
echo "Target revision: $TARGET_REVISION"

helm template cluster-forge "${SOURCE_ROOT}/root" \
    --show-only templates/cluster-forge.yaml \
    -f "${SOURCE_ROOT}/root/${VALUES_FILE}" \
    -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" \
    --set global.domain="${DOMAIN}" \
    --set clusterForge.targetRevision="${TARGET_REVISION}" \
    --set externalValues.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git" \
    --set clusterForge.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git" \
    --namespace argocd \
    --kube-version "${KUBE_VERSION}" | kubectl apply -f -

cat <<__SUMMARY__

=== ClusterForge Bootstrap Complete ===

Domain: $DOMAIN
Cluster size: $CLUSTER_SIZE
Target revision: $TARGET_REVISION

🌐 Access URLs:
  ArgoCD:  https://argocd.${DOMAIN}
  OpenBao: https://openbao.${DOMAIN}
  Gitea:   https://gitea.${DOMAIN}

  Credentials:
    ArgoCD admin username: admin
    ArgoCD admin password: (check argocd-initial-admin-secret in argocd namespace)
    OpenBao token: (check openbao-initial-admin-secret in cf-openbao namespace
    Gitea admin username: silogen-admin
    Gitea admin password: (check gitea-admin-credentials secret in cf-gitea namespace)

📋 What happens now:
  1. ✅ ArgoCD is running and managing the cluster
  2. ✅ OpenBao provides secrets management and is fully initialized
  3. ✅ Gitea provides git source of truth ArgoCD (unless cluster size is small)
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
rm -f /tmp/simple_values.yaml
