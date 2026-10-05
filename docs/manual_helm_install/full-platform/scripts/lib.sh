# shellcheck shell=bash
# Shared settings for the dependency scripts. Source this file; do not execute it.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "source deps/lib.sh from another script" >&2
  exit 1
fi

: "${DOMAIN:?export DOMAIN}"
: "${STORAGE_CLASS:?export STORAGE_CLASS}"

DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SECRETS_FILE:-${DEPS_DIR}/.secrets.env}"
CHART_VERSION="${CHART_VERSION:-2.0.3}"
# shellcheck disable=SC2034  # each script that sources lib.sh reads OCI
OCI="oci://registry-1.docker.io/amdenterpriseai"

hex() { openssl rand -hex 16; }

if [[ ! -f "${SECRETS_FILE}" ]]; then
  umask 077
  {
    echo "KEYCLOAK_ADMIN_PASSWORD=$(hex)"
    echo "KEYCLOAK_DB_PASSWORD=$(hex)"
    echo "KEYCLOAK_SUPERUSER_PASSWORD=$(hex)"
    echo "KEYCLOAK_UI_CLIENT_SECRET=$(hex)"
    echo "KEYCLOAK_ADMIN_CLIENT_ID=airm-admin"
    echo "KEYCLOAK_ADMIN_CLIENT_SECRET=$(hex)"
    echo "CI_CLIENT_SECRET=$(hex)"
    echo "K8S_CLIENT_SECRET=$(hex)"
    echo "MINIO_CLIENT_SECRET=$(hex)"
    echo "GITEA_CLIENT_SECRET=$(hex)"
    echo "ARGOCD_CLIENT_SECRET=$(hex)"
    echo "DEVUSER_PASSWORD=$(hex)"
    echo "AIRM_DB_PASSWORD=$(hex)"
    echo "AIRM_DB_SUPERUSER_PASSWORD=$(hex)"
    echo "AIWB_DB_PASSWORD=$(hex)"
    echo "AIWB_DB_SUPERUSER_PASSWORD=$(hex)"
    echo "RABBITMQ_ADMIN_PASSWORD=$(hex)"
    echo "AIRM_NEXTAUTH_SECRET=$(hex)"
    echo "AIWB_NEXTAUTH_SECRET=$(hex)"
    echo "MINIO_ACCESS_KEY=$(hex)"
    echo "MINIO_SECRET_KEY=$(hex)"
    echo "CLUSTER_AUTH_TOKEN=$(hex)"
    echo "OPENBAO_TOKEN=$(hex)"
    echo "OPENBAO_READONLY_PASSWORD=$(hex)"
    echo "SEAWEED_ADMIN_PASSWORD=$(hex)"
    echo "MINIO_CONSOLE_ACCESS_KEY=$(hex)"
    echo "MINIO_CONSOLE_SECRET_KEY=$(hex)"
    echo "MINIO_ROOT_PASSWORD=$(hex)"
    echo "GRAFANA_ADMIN_PASSWORD=$(hex)"
  } > "${SECRETS_FILE}"
  echo "wrote ${SECRETS_FILE}"
fi

set -a
# shellcheck disable=SC1090
source "${SECRETS_FILE}"
set +a

ensure_ns() {
  kubectl create namespace "$1" --dry-run=client --output yaml | kubectl apply --filename -
}

ksecret() {
  local ns="$1" name="$2"
  shift 2
  kubectl create secret generic "${name}" --namespace "${ns}" "$@" \
    --dry-run=client --output yaml | kubectl apply --filename -
}

ensure_cnpg_operator() {
  helm repo add --force-update cnpg https://cloudnative-pg.github.io/charts
  helm repo update cnpg
  helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
    --version 0.26.0 \
    --namespace cnpg-system --create-namespace \
    --wait --timeout 6m
}

# Helm 4 writes the OCI `Pulled:` and `Digest:` lines to stdout, where Helm 3
# wrote them to stderr. kubectl then reads the first line as a YAML document
# and refuses the whole stream. The manifest starts at the first `---`.
yaml_only() {
  sed -n '/^---/,$p'
}

helm_manifest() {
  helm template "$@" | yaml_only
}

forge_dir() {
  local dest="${CLUSTER_FORGE_DIR:-${DEPS_DIR}/.cluster-forge}"
  if [[ ! -d "${dest}/sources" ]]; then
    git clone --depth 1 --branch "${CLUSTER_FORGE_REF:-main}" \
      https://github.com/silogen/cluster-forge.git "${dest}"
  fi
  printf '%s\n' "${dest}"
}
