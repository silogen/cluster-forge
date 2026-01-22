#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${1:-}"
VALUES_FILE="${2:-values_cf.yaml}"
KUBE_VERSION=1.33

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

# Create namespaces
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

# ArgoCD bootstrap
helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 -f ${SCRIPT_DIR}/../sources/argocd/${VALUES_FILE} --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 -f ${SCRIPT_DIR}/../sources/openbao/values_cf.yaml \
  --namespace cf-openbao --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s

# Deploy OpenBao secret configurations needed for init job
echo "Deploying OpenBao secret configurations for init job..."
cat ${SCRIPT_DIR}/../sources/openbao-config/openbao-secret-definitions.yaml | \
  sed "s|{{ .Values.domain }}|${DOMAIN}|g" | kubectl apply -f -
cat ${SCRIPT_DIR}/../sources/openbao-config/openbao-secret-manager-cm.yaml | kubectl apply -f -

# Deploy OpenBao initialization job
helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Gitea bootstrap
generate_password() {
    openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
}

# Create initial-cf-values configmap
VALUES=$(cat ${SCRIPT_DIR}/../root/${VALUES_FILE} | yq ".global.domain = \"${DOMAIN}\"")
kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -

kubectl create secret generic gitea-admin-credentials \
  --namespace=cf-gitea \
  --from-literal=username=silogen-admin \
  --from-literal=password=$(generate_password)
helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 -f ${SCRIPT_DIR}/../sources/gitea/values_cf.yaml --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps
helm template ${SCRIPT_DIR}/../root -f ${SCRIPT_DIR}/../root/${VALUES_FILE} --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
