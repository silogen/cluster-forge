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
helm template --release-name openbao-init ./init-openbao-job --set domain="$DOMAIN" --kube-version=${KUBE_VERSION} | kubectl apply -f -
if ! kubectl wait --for=condition=complete --timeout=60s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Copy the cluster-tls secret from kgateway-system to the minio tenant default namespace, unless it already exists
if kubectl get ns kgateway-system &> /dev/null && kubectl get ns minio-tenant-default &> /dev/null; then
  if ! kubectl get secret cluster-tls -n minio-tenant-default &> /dev/null; then
    kubectl get secret cluster-tls -n kgateway-system -o yaml | sed 's/namespace: kgateway-system/namespace: minio-tenant-default/' | kubectl apply -f -
  fi
fi

# Create ArgoCD cluster-forge app
helm template ../root -f ../root/${VALUES_FILE} --kube-version=${KUBE_VERSION} | kubectl apply -f -
