#!/usr/bin/env bash
# Copy the semantic-router blueprint into the current git repository.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "${script_dir}/.." && pwd)

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Run this script from the root of the cluster-values repository." >&2
  exit 1
fi

dest=$(git rev-parse --show-toplevel)
if [[ "$(pwd -P)" != "${dest}" ]]; then
  echo "Run this script from the repository root: ${dest}" >&2
  exit 1
fi

blueprint_repo=$(git -C "${src}" rev-parse --show-toplevel)
if [[ "${blueprint_repo}" == "${dest}" ]]; then
  echo "Run this script from the root of the cluster-values repository." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not available. Point kubectl at the cluster, then start the script again." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is not available. Install openssl, then start the script again." >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is not available. Install mikefarah yq, then start the script again." >&2
  exit 1
fi

yq_version=$(yq --version 2>&1 || true)
if [[ "${yq_version}" != *mikefarah* ]]; then
  echo "yq is not mikefarah yq. Install mikefarah yq, then start the script again." >&2
  exit 1
fi

if ! domain=$(kubectl get configmap cluster-domain --namespace default --output jsonpath='{.data.DOMAIN}'); then
  echo "kubectl did not read the cluster domain." >&2
  echo "Point kubectl at the cluster, then start the script again." >&2
  exit 1
fi
# cluster-bloom writes key DOMAIN. The manual install guide writes key domain.
if [[ -z "${domain}" ]]; then
  domain=$(kubectl get configmap cluster-domain --namespace default --output jsonpath='{.data.domain}')
fi

domain_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
if [[ ! "${domain}" =~ ${domain_re} ]]; then
  echo "The cluster domain from kubectl is not a host name: '${domain}'." >&2
  exit 1
fi

# Escape characters that are special in the sed replacement.
sed_domain=${domain//\\/\\\\}
sed_domain=${sed_domain//&/\\&}
sed_domain=${sed_domain//#/\\#}

echo "Blueprint: ${src}"
echo "Destination: ${dest}"
echo "Cluster domain: ${domain}"

# Replace only the semantic-router key. Keep every other extraApps entry.
if [[ ! -s extra-apps-values.yaml ]]; then
  printf '%s\n' 'extraApps: {}' > extra-apps-values.yaml
fi

extra_apps_type=$(yq eval '.extraApps | type' extra-apps-values.yaml)
if [[ "${extra_apps_type}" != "!!map" && "${extra_apps_type}" != "!!null" ]]; then
  echo "extraApps in extra-apps-values.yaml is not a map. The script does not change that file." >&2
  exit 1
fi

BLUEPRINT_EXTRA_APPS="${src}/extraApps.yaml" \
  yq eval -i '.extraApps.semantic-router = load(strenv(BLUEPRINT_EXTRA_APPS)).extraApps.semantic-router' extra-apps-values.yaml

mkdir -p extra-apps/semantic-router/manifests
cp "${src}/values.yaml" extra-apps/semantic-router/values.yaml
cp "${src}/manifests/gateway-routing.yaml" extra-apps/semantic-router/manifests/
cp "${src}/manifests/dashboard-admin-externalsecret.yaml" extra-apps/semantic-router/manifests/

aigw_files=(
  sr-gateway.yaml
  sr-gateway-config.yaml
  sr-gateway-proxy-config.yaml
  sr-gateway-service.yaml
  sr-gateway-extproc.yaml
)
for f in "${aigw_files[@]}"; do
  cp "${src}/manifests/aigw-extras/${f}" extra-apps/semantic-router/manifests/
done

sed -i \
  -e "s#sr-dashboard\\.mycluster\\.example\\.com#sr-dashboard.${sed_domain}#" \
  -e 's/TODO-your-vllm-service:8000/test-vllm.semantic-router.svc:8000/' \
  -e 's/TODO-your-model/smoke-test-model/g' \
  extra-apps/semantic-router/values.yaml

sed -i \
  -e "s#sr\\.mycluster\\.example\\.com#sr.${sed_domain}#" \
  -e 's/TODO-your-vllm-service\.TODO-your-vllm-namespace\.svc\.cluster\.local/test-vllm.semantic-router.svc.cluster.local/' \
  -e 's/TODO-your-model-backend/smoke-test-backend/g' \
  -e 's/TODO-your-backend-model/smoke-test-model/g' \
  -e 's/TODO-your-model/smoke-test-model/g' \
  -e 's/TODO-your-client-name/smoke-client/g' \
  extra-apps/semantic-router/manifests/gateway-routing.yaml

git add extra-apps-values.yaml extra-apps/semantic-router
if ! git diff --cached --quiet; then
  git commit -m "feat: Add semantic-router extra app"
  git push
else
  echo "No file changes to commit."
fi

# The Secret stays on the cluster. Do not write the key into this repository.
if ! kubectl get namespace semantic-router >/dev/null 2>&1; then
  kubectl create namespace semantic-router
fi

if kubectl -n semantic-router get secret semantic-router-client-keys >/dev/null 2>&1; then
  echo "Secret semantic-router-client-keys already exists. The script does not replace it."
else
  smoke_key=$(openssl rand -hex 32)
  kubectl -n semantic-router create secret generic semantic-router-client-keys \
    --from-literal=smoke-client="${smoke_key}"
  echo "smoke-client API key: ${smoke_key}"
fi
