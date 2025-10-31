#!/bin/bash

DOMAIN="${1:-}"
VALUES_FILE="${2:-values_dev.yaml}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Create namespaces
kubectl create ns argocd
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
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s
helm template --release-name openbao-init ./init-openbao-job --set domain="$DOMAIN" | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=60s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/${VALUES_FILE} | kubectl apply -f -
