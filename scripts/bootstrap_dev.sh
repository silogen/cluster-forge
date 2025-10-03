#!/bin/bash

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain>"
    exit 1
fi

# Update values_cf.yaml
yq eval '.common.domain = "'${DOMAIN}'"' -i ../root/values.yaml

# Create namespaces
kubectl create ns argocd
kubectl create ns cf-gitea
kubectl create ns cf-openbao

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.0 --namespace argocd | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
helm template --release-name openbao ../sources/openbao/0.18.2 -f ../sources/openbao/values_cf.yaml \
  --namespace cf-openbao | kubectl apply -f -
kubectl wait --for=condition=initialized --timeout=60s pod/openbao-0 -n cf-openbao
kubectl apply -f ./init-openbao-job/
if ! kubectl wait --for=condition=complete --timeout=60s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/values.yaml --set common.domain=${DOMAIN} | kubectl apply -f -
