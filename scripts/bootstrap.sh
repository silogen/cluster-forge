#!/bin/bash

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain>"
    exit 1
fi

# Update values_cf.yaml
yq eval '.common.domain = "'${DOMAIN}'"' -i ../root/values_cf.yaml

# Create namespaces
kubectl create ns argocd
kubectl create ns cf-gitea

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.0 --namespace argocd | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# Initial secrets bootstrap
# TODO: OpenBao bootstrap
kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=password

# Gitea bootstrap
kubectl create configmap initial-cf-values --from-file=../root/values_cf.yaml -n cf-gitea
helm upgrade --install gitea ../sources/gitea/12.3.0 -f ../sources/gitea/values_cf.yaml --namespace cf-gitea \
  --set clusterDomain=${DOMAIN} --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}"
kubectl rollout status deploy/gitea -n cf-gitea
kubectl apply -f ./init-gitea-job/

# Create ArgoCD cluster-forge app
if kubectl wait --for=condition=complete --timeout=60s job/gitea-init-job -n cf-gitea; then
  echo "Job gitea-init-job completed successfully, proceeding with cluster-forge app"
  helm template ../root -f ../root/values_cf.yaml --set common.domain=${DOMAIN} | kubectl apply -f -
else
  echo "ERROR: Job gitea-init-job failed to complete or timed out!"
  exit 1
fi