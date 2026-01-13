#!/bin/bash

set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    exit 1
fi

KUBE_VERSION=1.33
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../root/" && pwd)"
SOURCES_DIR="$(cd "${SCRIPT_DIR}/../sources" && pwd)"
VALUES_FILE="${2:-values.yaml}"

bootstrapArgocd() {
  kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -

  helm template --release-name argocd  \
    ${SOURCES_DIR}/argocd/8.3.5 \
    --kube-version=${KUBE_VERSION} \
    --namespace argocd \
    --set global.domain="https://argocd.${DOMAIN}" \
    --values <(yq '.apps.argocd.valuesObject' ${ROOT_DIR}/${VALUES_FILE}) \
    | kubectl apply -f -
  
  kubectl rollout status statefulset/argocd-application-controller -n argocd
  kubectl rollout status deploy/argocd-applicationset-controller -n argocd
  kubectl rollout status deploy/argocd-redis -n argocd
  kubectl rollout status deploy/argocd-repo-server -n argocd
}

bootstrapOpenbao() {
  kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

  helm template --release-name openbao \
    ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
    --kube-version=${KUBE_VERSION} \
    --namespace cf-openbao \
    --values <(yq '.apps.openbao.valuesObject' ${ROOT_DIR}/${VALUES_FILE}) \
    | kubectl apply -f -

  kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s

  helm template --release-name openbao-init \
    ${SCRIPT_DIR}/init-openbao-job \
    --kube-version=${KUBE_VERSION} \
    --set domain="${DOMAIN}" \
    | kubectl apply -f -

  kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
}

bootstrapGitea() {
  kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -

  # Create initial-cf-values configmap
  VALUES=$(cat ${ROOT_DIR}/${VALUES_FILE} | yq ".global.domain = \"${DOMAIN}\"")
  kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -
  
  GITEA_INITIAL_ADMIN_PASSWORD=$(openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32)
  kubectl create secret generic gitea-admin-credentials \
    --namespace=cf-gitea \
    --from-literal=username=silogen-admin \
    --from-literal=password="$GITEA_INITIAL_ADMIN_PASSWORD"
  
  helm template --release-name gitea \
    ${SOURCES_DIR}/gitea/12.3.0 \
    --kube-version=${KUBE_VERSION} \
    --namespace cf-gitea \
    --set clusterDomain="${DOMAIN}" \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" \
    --values <(yq '.apps.gitea.valuesObject' ${ROOT_DIR}/${VALUES_FILE}) \
    | kubectl apply -f -
  
  kubectl rollout status deploy/gitea -n cf-gitea
  helm template --release-name gitea-init \
    ${SCRIPT_DIR}/init-gitea-job \
    --kube-version=${KUBE_VERSION} \
    --set domain="${DOMAIN}" \
    | kubectl apply -f -
  
  kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea
}

deployClusterForge() {
  helm template ${ROOT_DIR} \
    --kube-version=${KUBE_VERSION} \
    --set global.domain="${DOMAIN}" \
    --values ${ROOT_DIR}/${VALUES_FILE} \
    | kubectl apply -f -
}

#### MAIN ####
bootstrapArgocd
bootstrapOpenbao
bootstrapGitea
deployClusterForge