#!/usr/bin/env bash
# Kubernetes Secrets the AIRM and AIWB charts read.
# Skip this when deps/external-secrets.sh syncs the same Secrets from openbao-secret-store.
# Does not create airm-rabbitmq-common-vhost-user.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_ns airm
ensure_ns aiwb

ksecret airm airm-cnpg-user \
  --from-literal=username=airm_user \
  --from-literal=password="${AIRM_DB_PASSWORD}"
ksecret airm airm-cnpg-superuser \
  --from-literal=username=postgres \
  --from-literal=password="${AIRM_DB_SUPERUSER_PASSWORD}"
ksecret airm airm-keycloak-admin-client \
  --from-literal=client-id="${KEYCLOAK_ADMIN_CLIENT_ID}" \
  --from-literal=client-secret="${KEYCLOAK_ADMIN_CLIENT_SECRET}"
ksecret airm airm-keycloak-ui-creds \
  --from-literal=KEYCLOAK_SECRET="${KEYCLOAK_UI_CLIENT_SECRET}"
ksecret airm airm-user-credentials \
  --from-literal=USER_PASSWORD="${DEVUSER_PASSWORD}"
ksecret airm airm-rabbitmq-admin \
  --from-literal=username=admin \
  --from-literal=password="${RABBITMQ_ADMIN_PASSWORD}" \
  --from-literal=default_user.conf="$(printf 'default_user = admin\ndefault_pass = %s\n' "${RABBITMQ_ADMIN_PASSWORD}")"
ksecret airm airm-secrets-airm \
  --from-literal=NEXTAUTH_SECRET="${AIRM_NEXTAUTH_SECRET}"

ksecret aiwb aiwb-cnpg-user \
  --from-literal=username=aiwb_user \
  --from-literal=password="${AIWB_DB_PASSWORD}"
ksecret aiwb aiwb-cnpg-superuser \
  --from-literal=username=postgres \
  --from-literal=password="${AIWB_DB_SUPERUSER_PASSWORD}"
ksecret aiwb aiwb-ui-keycloak-secret \
  --from-literal=value="${KEYCLOAK_UI_CLIENT_SECRET}"
ksecret aiwb aiwb-nextauth-secret \
  --from-literal=NEXTAUTH_SECRET="${AIWB_NEXTAUTH_SECRET}"
ksecret aiwb minio-credentials \
  --from-literal=minio-access-key="${MINIO_ACCESS_KEY}" \
  --from-literal=minio-secret-key="${MINIO_SECRET_KEY}"
ksecret aiwb cluster-auth-admin-token \
  --from-literal=value="${CLUSTER_AUTH_TOKEN}"
ksecret aiwb aiwb-openbao-token \
  --from-literal=value="${OPENBAO_TOKEN}"
