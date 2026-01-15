#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${1:-}"
VALUES_FILE="${2:-values.yaml}"
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
# Create temporary merged values file for ArgoCD
ARGOCD_MERGED_CONFIG="/tmp/bootstrap-argocd-$$.yaml"
echo "apps:" > "$ARGOCD_MERGED_CONFIG"
echo "  argocd:" >> "$ARGOCD_MERGED_CONFIG" 
echo "    valuesObject: {}" >> "$ARGOCD_MERGED_CONFIG"

# Merge valuesObject from the root values file
if yq -e '.apps.argocd.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
  yq eval-all 'select(fileIndex == 0).apps.argocd.valuesObject *= select(fileIndex == 1).apps.argocd.valuesObject' \
    "$ARGOCD_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${ARGOCD_MERGED_CONFIG}.tmp"
  mv "${ARGOCD_MERGED_CONFIG}.tmp" "$ARGOCD_MERGED_CONFIG"
fi

helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \
  --values <(yq '.apps.argocd.valuesObject' "$ARGOCD_MERGED_CONFIG") \
  --namespace argocd \
  --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -

rm -f "$ARGOCD_MERGED_CONFIG"

kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd

# OpenBao bootstrap
# Create temporary merged values file for OpenBao
OPENBAO_MERGED_CONFIG="/tmp/bootstrap-openbao-$$.yaml"
echo "apps:" > "$OPENBAO_MERGED_CONFIG"
echo "  openbao:" >> "$OPENBAO_MERGED_CONFIG"
echo "    valuesObject: {}" >> "$OPENBAO_MERGED_CONFIG"

# Merge valuesObject from the root values file
if yq -e '.apps.openbao.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
  yq eval-all 'select(fileIndex == 0).apps.openbao.valuesObject *= select(fileIndex == 1).apps.openbao.valuesObject' \
    "$OPENBAO_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${OPENBAO_MERGED_CONFIG}.tmp"
  mv "${OPENBAO_MERGED_CONFIG}.tmp" "$OPENBAO_MERGED_CONFIG"
fi

helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
  --values <(yq '.apps.openbao.valuesObject' "$OPENBAO_MERGED_CONFIG") \
  --namespace cf-openbao --kube-version=${KUBE_VERSION} | kubectl apply -f -

rm -f "$OPENBAO_MERGED_CONFIG"

kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
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

# Create temporary merged values file for Gitea
GITEA_MERGED_CONFIG="/tmp/bootstrap-gitea-$$.yaml"
echo "apps:" > "$GITEA_MERGED_CONFIG"
echo "  gitea:" >> "$GITEA_MERGED_CONFIG"
echo "    valuesObject: {}" >> "$GITEA_MERGED_CONFIG"

# Merge valuesObject from the root values file
if yq -e '.apps.gitea.valuesObject' "${SCRIPT_DIR}/../root/${VALUES_FILE}" >/dev/null 2>&1; then
  yq eval-all 'select(fileIndex == 0).apps.gitea.valuesObject *= select(fileIndex == 1).apps.gitea.valuesObject' \
    "$GITEA_MERGED_CONFIG" "${SCRIPT_DIR}/../root/${VALUES_FILE}" > "${GITEA_MERGED_CONFIG}.tmp"
  mv "${GITEA_MERGED_CONFIG}.tmp" "$GITEA_MERGED_CONFIG"
fi

helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
  --values <(yq '.apps.gitea.valuesObject' "$GITEA_MERGED_CONFIG") \
  --namespace cf-gitea \
  --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -

rm -f "$GITEA_MERGED_CONFIG"

kubectl rollout status deploy/gitea -n cf-gitea
helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -
kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea

# Create cluster-forge app-of-apps
helm template ${SCRIPT_DIR}/../root -f ${SCRIPT_DIR}/../root/${VALUES_FILE} --set global.domain="${DOMAIN}" --kube-version=${KUBE_VERSION} | kubectl apply -f -