#!/usr/bin/env bash
# OpenBao 0.18.2 in dev mode and ClusterSecretStore openbao-secret-store.
# Dev mode discards data when the pod restarts. For a durable server, leave
# server.dev.enabled unset and initialize with bao operator init.
# Writes every key the external-secrets charts and the AIRM configure job read.
# helm --wait can return before the container accepts kubectl exec.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

helm repo add --force-update openbao https://openbao.github.io/openbao-helm
helm repo update openbao

helm upgrade --install openbao openbao/openbao --version 0.18.2 \
  --namespace cf-openbao --create-namespace \
  --set injector.enabled=false \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken="${OPENBAO_TOKEN}" \
  --set server.dataStorage.enabled=false \
  --wait --timeout 6m

kubectl wait --for=condition=ready pod/openbao-0 --namespace cf-openbao --timeout=180s

bao() {
  kubectl exec --namespace cf-openbao openbao-0 -- env \
    BAO_ADDR=http://127.0.0.1:8200 \
    BAO_TOKEN="${OPENBAO_TOKEN}" \
    bao "$@"
}

bao secrets enable -path=secrets kv-v2 || true
bao auth enable userpass || true
kubectl exec --stdin --namespace cf-openbao openbao-0 -- env \
  BAO_ADDR=http://127.0.0.1:8200 \
  BAO_TOKEN="${OPENBAO_TOKEN}" \
  bao policy write readonly - <<'EOF'
path "secrets/data/*" {
  capabilities = ["read"]
}
path "secrets/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
bao write auth/userpass/users/readonly-user \
  password="${OPENBAO_READONLY_PASSWORD}" \
  policies=readonly

kv() { bao kv put "secrets/$1" value="$2"; }
kv minio-api-access-key "${MINIO_ACCESS_KEY}"
kv minio-api-secret-key "${MINIO_SECRET_KEY}"
kv minio-console-access-key "${MINIO_CONSOLE_ACCESS_KEY}"
kv minio-console-secret-key "${MINIO_CONSOLE_SECRET_KEY}"
kv minio-root-password "${MINIO_ROOT_PASSWORD}"
kv minio-client-secret "${MINIO_CLIENT_SECRET}"
kv minio-openid-url "https://kc.${DOMAIN}/realms/airm"
kv aiwb-openbao-token "${OPENBAO_TOKEN}"
kv airm-cnpg-superuser-username postgres
kv airm-cnpg-superuser-password "${AIRM_DB_SUPERUSER_PASSWORD}"
kv airm-cnpg-user-username airm_user
kv airm-cnpg-user-password "${AIRM_DB_PASSWORD}"
kv airm-keycloak-admin-client-id "${KEYCLOAK_ADMIN_CLIENT_ID}"
kv airm-keycloak-admin-client-secret "${KEYCLOAK_ADMIN_CLIENT_SECRET}"
kv airm-ui-keycloak-secret "${KEYCLOAK_UI_CLIENT_SECRET}"
kv keycloak-initial-devuser-password "${DEVUSER_PASSWORD}"
kv airm-rabbitmq-user-username admin
kv airm-rabbitmq-user-password "${RABBITMQ_ADMIN_PASSWORD}"
kv airm-ui-auth-nextauth-secret "${AIRM_NEXTAUTH_SECRET}"
kv aiwb-cnpg-superuser-username postgres
kv aiwb-cnpg-superuser-password "${AIWB_DB_SUPERUSER_PASSWORD}"
kv aiwb-cnpg-user-password "${AIWB_DB_PASSWORD}"
kv aiwb-ui-auth-nextauth-secret "${AIWB_NEXTAUTH_SECRET}"
kv cluster-auth-admin-token "${CLUSTER_AUTH_TOKEN}"

ensure_ns aiwb
ksecret cf-openbao openbao-user \
  --from-literal=password="${OPENBAO_READONLY_PASSWORD}"
ksecret aiwb aiwb-openbao-token \
  --from-literal=value="${OPENBAO_TOKEN}"

kubectl apply --filename - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: openbao-secret-store
spec:
  provider:
    vault:
      auth:
        userPass:
          path: userpass
          username: readonly-user
          secretRef:
            name: openbao-user
            key: password
            namespace: cf-openbao
      path: secrets
      server: http://openbao.cf-openbao.svc.cluster.local:8200
      version: v2
EOF
