#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${1:-}"
VALUES_FILE="${2:-values_dev.yaml}"
KUBE_VERSION=1.33

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

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
if ! kubectl wait --for=condition=complete --timeout=360s job/openbao-init-job -n cf-openbao; then
  echo "ERROR: Job openbao-init-job failed to complete or timed out!"
  exit 1
fi

# Create cluster-forge app-of-apps
helm template ${SCRIPT_DIR}/../root -f ${SCRIPT_DIR}/../root/${VALUES_FILE} --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
