#!/bin/bash

set -euo pipefail

DOMAIN="${1:-}"
VALUES_FILE="${2:-values_dev.yaml}"
KUBE_VERSION=1.33

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Create namespaces
kubectl create ns argocd
kubectl create ns cf-openbao

# ArgoCD bootstrap
helm template --release-name argocd ../sources/argocd/8.3.5 --namespace argocd --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
helm template --release-name openbao ../sources/openbao/0.18.2 -f ../sources/openbao/values_cf.yaml \
  --namespace cf-openbao --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

# Create static ConfigMaps needed for init job
helm template --release-name openbao-config-static ./init-openbao-job --set domain="$DOMAIN" --kube-version=${KUBE_VERSION} \
  --show-only templates/openbao-secret-manager-cm.yaml | kubectl apply -f -

# Create initial secrets config for init job (separate from ArgoCD-managed version)
cat ../sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | \
  sed "s|{{ .Values.domain }}|$DOMAIN|g" | \
  sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -

# Deploy OpenBao initialization job
helm template --release-name openbao-init ./init-openbao-job --set domain="$DOMAIN" --kube-version=${KUBE_VERSION} | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=60s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/${VALUES_FILE} --kube-version=${KUBE_VERSION} | kubectl apply -f -
