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

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.0 --namespace argocd | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# Initial secrets bootstrap
# TODO: OpenBao bootstrap

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/values.yaml --set common.domain=${DOMAIN} | kubectl apply -f -