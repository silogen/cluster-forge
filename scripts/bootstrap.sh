#!/bin/bash

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain>"
    exit 1
fi

# Update values_cf.yaml
yq eval '.global.domain = "'${DOMAIN}'"' -i ../root/values_cf.yaml

# Create namespaces
kubectl create ns argocd
kubectl create ns cf-gitea
kubectl create ns cf-openbao

# Validate Longhorn is ready before continuing:
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "$script_dir/wait_for_longhorn.sh" ]; then
  if ! "$script_dir/wait_for_longhorn.sh"; then
    echo "ERROR: Longhorn readiness check failed!"
    exit 1
  fi
else
  if [ -f "$script_dir/wait_for_longhorn.sh" ]; then
    if ! bash "$script_dir/wait_for_longhorn.sh"; then
      echo "ERROR: Longhorn readiness check failed!"
      exit 1
    fi
  else
    echo "ERROR: wait_for_longhorn.sh not found in $script_dir"
    exit 1
  fi
fi

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.5 -f ../sources/argocd/values_cf.yaml --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
helm template --release-name openbao ../sources/openbao/0.18.2 -f ../sources/openbao/values_cf.yaml \
  --namespace cf-openbao | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
helm template --release-name openbao-init ./init-openbao-job --set domain="${DOMAIN}" | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Gitea bootstrap
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password)
kubectl create configmap initial-cf-values --from-file=../root/values_cf.yaml -n cf-gitea
helm template --release-name gitea ../sources/gitea/12.3.0 -f ../sources/gitea/values_cf.yaml --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ./init-gitea-job --set domain="${DOMAIN}" | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea; then
  echo "ERROR: Job gitea-init-job failed to complete or timed out!"
  exit 1
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/values_cf.yaml --set global.domain="${DOMAIN}" | kubectl apply -f -
