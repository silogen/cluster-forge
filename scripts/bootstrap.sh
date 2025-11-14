#!/bin/bash

DOMAIN="${1:-}"
VALUES_FILE="${2:-values_cf.yaml}"
KUBE_VERSION=1.33

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Update values file
yq eval '.global.domain = "'${DOMAIN}'"' -i ../root/${VALUES_FILE}

# Create namespaces
kubectl create ns argocd
kubectl create ns cf-gitea
kubectl create ns cf-openbao

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.5 -f ../sources/argocd/values_cf.yaml --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
helm template --release-name openbao ../sources/openbao/0.18.2 -f ../sources/openbao/values_cf.yaml \
  --namespace cf-openbao --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
helm template --release-name openbao-init ./init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
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
kubectl create configmap initial-cf-values --from-file=../root/${VALUES_FILE} -n cf-gitea
helm template --release-name gitea ../sources/gitea/12.3.0 -f ../sources/gitea/values_cf.yaml --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ./init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea; then
  echo "ERROR: Job gitea-init-job failed to complete or timed out!"
  exit 1
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/${VALUES_FILE} --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
