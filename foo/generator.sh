#!/bin/bash

bao kv put kv/airm loki_tenant_name_oci1=loki_tenant_oci1
bao kv patch kv/airm loki_tenant_name_oci2=loki_tenant_oci2
bao kv patch kv/airm loki_tenant_name_ocisilogen=loki_tenant_ocisilogen
bao kv patch kv/airm loki_tenant_name_ociops=loki_tenant_ociops
bao kv patch kv/airm loki_tenant_password_ociclusters=loki_tenant_password_ociclusters
bao kv patch kv/airm .htpasswd="cluster-forge-mimir-test-user:\$apr1\$mszGHRfu\$fDCiA32oRdtP8tXGTTn2M0"
bao kv patch kv/airm grafana-admin-id=admin
bao kv patch kv/airm grafana-admin-pw=password
bao kv patch kv/airm airm-ui-keycloak-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-keycloak-admin-client-id=admin-client-id-value
bao kv patch kv/airm airm-keycloak-admin-client-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-ci-client-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-airm-cnpg-user=airm-airm-cnpg-user
bao kv patch kv/airm catalog-cnpg-superuser="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm catalog-cnpg-user="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm catalog-cnpg-user-username="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm chat-legacy-auth-nextauth-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm docker-pull-k8s-external-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-client-frontend-keycloak-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-credentials="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm silogen-realm-credentials="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-realm-credentials="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-client-internal-keycloak-id="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-client-internal-keycloak-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-client-ci-keycloak-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-initial-admin-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-cnpg-user-username=keycloak
bao kv patch kv/airm keycloak-cnpg-superuser-username="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-cnpg-superuser-username="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-cnpg-user-username=airm_user
bao kv patch kv/airm airm-rabbitmq-user-username="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-oci-1-rabbitmq-common-vhost-username="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-rabbitmq-backup-minio-credentials="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-cnpg-superuser-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm keycloak-cnpg-user-password=keycloak
bao kv patch kv/airm keycloak_initial_admin_password=admin
bao kv patch kv/airm airm-cnpg-superuser-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-cnpg-user-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-rabbitmq-user-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-oci-1-rabbitmq-common-vhost-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm hmac-keys-access-key="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm hmac-keys-secret-key="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm docker-pull-k8s-external-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm airm-legacy-auth-nextauth-secret="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
bao kv patch kv/airm rabbitmq-default-user-username=username
bao kv patch kv/airm rabbitmq-default-user-password="$(bao write -field=random_bytes sys/tools/random bytes=32 format=hex)"
