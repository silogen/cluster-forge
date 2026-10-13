#!/usr/bin/env bash
# Keycloak from cluster-forge sources/keycloak-old, realm airm, client 354a0fa1-35ac-4a6d-9c4d-d661129c2cd0.
# Realm import uses sed. Passwords are hex so the delimiter stays intact.
# AIRM reads http://keycloak.keycloak.svc.cluster.local:8080.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

forge="$(forge_dir)"
ensure_cnpg_operator
ensure_ns keycloak

ksecret keycloak keycloak-credentials \
  --from-literal=KEYCLOAK_INITIAL_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"
ksecret keycloak keycloak-cnpg-user \
  --from-literal=username=keycloak \
  --from-literal=password="${KEYCLOAK_DB_PASSWORD}"
ksecret keycloak keycloak-cnpg-superuser \
  --from-literal=username=postgres \
  --from-literal=password="${KEYCLOAK_SUPERUSER_PASSWORD}"
ksecret keycloak airm-realm-credentials \
  --from-literal=FRONTEND_CLIENT_SECRET="${KEYCLOAK_UI_CLIENT_SECRET}" \
  --from-literal=ADMIN_CLIENT_ID="${KEYCLOAK_ADMIN_CLIENT_ID}" \
  --from-literal=ADMIN_CLIENT_SECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET}" \
  --from-literal=CI_CLIENT_SECRET="${CI_CLIENT_SECRET}" \
  --from-literal=K8S_CLIENT_SECRET="${K8S_CLIENT_SECRET}" \
  --from-literal=MINIO_CLIENT_SECRET="${MINIO_CLIENT_SECRET}" \
  --from-literal=GITEA_CLIENT_SECRET="${GITEA_CLIENT_SECRET}" \
  --from-literal=ARGOCD_CLIENT_SECRET="${ARGOCD_CLIENT_SECRET}" \
  --from-literal=KEYCLOAK_INITIAL_DEVUSER_PASSWORD="${DEVUSER_PASSWORD}"

helm upgrade --install keycloak "${forge}/sources/keycloak-old" \
  --namespace keycloak \
  --set externalSecrets.enabled=false \
  --set domain="${DOMAIN}" \
  --set cnpg.storage.storageClassName="${STORAGE_CLASS}" \
  --set storageClassName="${STORAGE_CLASS}" \
  --wait --timeout 15m
