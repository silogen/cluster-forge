#!/bin/bash

# Install deps (argocd, yq, helm)
ARGO_VERSION=v3.2.0
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/$ARGO_VERSION/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

sudo snap install yq --classic
sudo snap install helm --classic
sudo apt install postgresql-client

# set globals

# used for backup file timestamps
export CURRENT_DATE=$(date +%Y-%m-%d)

# db credentials
export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)

export KEYCLOAK_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password' | base64 --decode)

export AIRM_DB_FILE=$HOME/airm_db_backup_$CURRENT_DATE.sql
export KEYCLOAK_DB_FILE=$HOME/keycloak_db_backup_$CURRENT_DATE.sql

# backup AIRM database
export PGPASSWORD=AIRM_DB_PASSWORD
pg_dump --clean -h 127.0.0.1 -U $AIRM_DB_USERNAME airm > $AIRM_DB_FILE
unset PGPASSWORD

# backup Keycloak database
export PGPASSWORD=KEYCLOAK_DB_PASSWORD
pg_dump --clean -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak > $KEYCLOAK_DB_FILE
unset PGPASSWORD

# TODO: bcakup RMQ data https://www.rabbitmq.com/docs/backup (Akshay for details)

# Turn off Clusterforge auto-sync
argocd app set clusterforge --sync-policy ""
argocd app set clusterforge --sync-policy automated --self-heal --prune

# Remove AIRM
argocd app delete airm
kubectl delete namespace airm

# Remove Keycloak
argocd app delete keycloak
argocd app delete keycloak-config
kubectl delete namespace keycloak

# Remove OpenTelemetry
argocd app delete otel-lgtm
argocd app delete opentelemetry-operator
# bounces here
#kubectl delete namespace otel-lgtm-stack

# Config-updater
argocd app delete config-updater

# Kaiwo
argocd app delete kaiwo-cluster-config
argocd app delete kaiwo
kubectl delete namespace kaiwo
kubectl delete namespace kaiwo-system

argocd app delete minio-tenant-k8s-secret
argocd app delete minio-tenant
kubectl delete namespace minio-tenant-default
sleep 15
kubectl delete namespace minio-operator

# perhaps bundled with OpenTelemetry above?
kubectl delete namespace otel-lgtm-stack

# Kueue
argocd app delete kueue
kubectl delete namespace kueue-system

# Kyverno
argocd app delete kyverno
kubectl delete namespace kyverno

# Mutating webhooks cleanup
kubectl delete mutatingwebhookconfigurations/kaiwo-job-mutating
kubectl delete mutatingwebhookconfigurations/kueue-mutating-webhook-configuration
kubectl delete mutatingwebhookconfigurations/opentelemetry-operator-mutating-webhook-configuration

# these three were deleted at this time, but bounced due to finalizers
# kubectl delete mutatingwebhookconfigurations/kyverno-policy-mutating-webhook-cfg
# kubectl delete mutatingwebhookconfigurations/kyverno-resource-mutating-webhook-cfg
# kubectl delete mutatingwebhookconfigurations/kyverno-verify-mutating-webhook-cfg

# Validating webhooks cleanup
kubectl delete validatingwebhookconfigurations/kaiwo-job-validating
kubectl delete validatingwebhookconfigurations/kueue-validating-webhook-configuration
kubectl delete validatingwebhookconfigurations/opentelemetry-operator-validating-webhook-configuration
# bounced and were done again later
# kubectl delete validatingwebhookconfigurations/kyverno-cel-exception-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-cleanup-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-exception-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-global-context-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-policy-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-resource-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/kyverno-ttl-validating-webhook-cfg
# kubectl delete validatingwebhookconfigurations/secretstore-validate

# Clusterforge
argocd app delete clusterforge

# Remaining Argo CD apps
argocd app delete amd-device-config
argocd app delete amd-gpu-operator
argocd app delete appwrapper
argocd app delete certmanager
argocd app delete cluster-airm-config
argocd app delete cluster-auto-pvc
argocd app delete cnpg-operator
argocd app delete external-secrets
argocd app delete gateway-api
argocd app delete k8s-cluster-secret-store
argocd app delete kgateway
argocd app delete kgateway-crds
argocd app delete kuberay-operator
argocd app delete kyverno
argocd app delete metallb
argocd app delete minio-operator
argocd app delete prometheus-crds
argocd app delete rabbitmq

# Remove kyverno finalizers
kubectl patch application/kyverno -p '{"metadata":{"finalizers":[]}}' --type=merge

# Mutate webhooks that were bounced earlier
kubectl delete mutatingwebhookconfigurations/kyverno-policy-mutating-webhook-cfg
kubectl delete mutatingwebhookconfigurations/kyverno-resource-mutating-webhook-cfg
kubectl delete mutatingwebhookconfigurations/kyverno-verify-mutating-webhook-cfg

# Validating webhooks that were bounced earlier
kubectl delete validatingwebhookconfigurations/kyverno-cel-exception-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-cleanup-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-exception-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-global-context-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-policy-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-resource-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/kyverno-ttl-validating-webhook-cfg
kubectl delete validatingwebhookconfigurations/secretstore-validate

# Second attempt to delete kueue and kyverno namespaces
kubectl delete namespace kueue-system --force --grace-period=0
kubectl delete namespace kyverno --force --grace-period=0
kubectl delete namespace minio-tenant-default --force --grace-period=0
kubectl delete namespace otel-lgtm-stack --force --grace-period=0

# Clusterqueues
kubectl delete clusterqueues/kaiwo --force --grace-period=0

# Clusterqueue finalizer removal
kubectl patch clusterqueue/kaiwo -p '{"metadata":{"finalizers":[]}}' --type=merge

# Unable to do this since finalizer is -kubernetes
# kubectl patch namespace/otel-lgtm-stack -p '{"metadata":{"finalizers":[]}}' --type=merge

# Validatingwebhookconfigurations
kubectl delete validatingwebhookconfigurations/amd-gpu-operator-kmm-validating-webhook-configuration
kubectl delete validatingwebhookconfigurations/appwrapper-validating-webhook-configuration
kubectl delete validatingwebhookconfigurations/cert-manager-webhook
kubectl delete validatingwebhookconfigurations/cnpg-validating-webhook-configuration
kubectl delete validatingwebhookconfigurations/externalsecret-validate
kubectl delete validatingwebhookconfigurations/longhorn-webhook-validator
kubectl delete validatingwebhookconfigurations/metallb-webhook-configuration

kubectl delete mutatingwebhookconfigurations/appwarapper-mutating-webhook-configuration
kubectl delete mutatingwebhookconfigurations/cert-manager-webhook
kubectl delete mutatingwebhookconfigurations/cnpg-mutating-webhook-configuration
kubectl delete mutatingwebhookconfigurations/longhorn-webhook-mutator

# Remove Kueue APIService
kubectl delete apiservice v1beta1.visibility.kueue.x-k8s.io --force --grace-period=0

# now able to remove OpenTelemetry namespace
kubectl delete namespace otel-lgtm-stack

# Remove remaining namespaces
kubectl delete namespace argocd
kubectl delete namespace cf-es-backend
kubectl delete namespace cf-gitea

# Re-install Clusterforge
mkdir /$HOME/cfv2 && cd $HOME/cfv2
git clone git@github.com:silogen/cluster-forge.git
cd cluster-forge
git checkout v1.5.0
cd scripts

# ensure Helm values file has clusterforge.targetRevision set to v1.5.0
yq -i '.clusterforge.targetRevision = "v1.5.0"' ../root/values.yaml

kubectl rollout restart daemonset longhorn-manager -n longhorn
kubectl rollout restart daemonset longhorn-csi-plugin -n longhorn
kubectl rollout restart daemonset engine-image-ei-c2d50bcc -n longhorn

# originally done before longhorn restarts, but moved to here
./bootstrap.sh silogen-demo.silogen.ai

# sync Argo CD apps (may be just browser cache?)
argocd app sync appwrapper --force
argocd app sync clusterforge --force
argocd app sync kaiwo-crds --force
argocd app sync prometheus-crds --force
argocd app sync minio-operator --force
argocd app sync rabbitmq --force

# Remove Kueue CRDs
kubectl delete crd/cohorts.kueue.x-k8s.io --force --grace-period=0

# delete failing sync operation (residue)
argocd app terminate-op kueue

# add check that pod airm-cnpg-1 is running in namespace airm before proceeding
export PGPASSWORD=AIRM_DB_PASSWORD
psql -h 127.0.0.1 -U $AIRM_DB_USERNAME airm < $AIRM_DB_FILE
unset PGPASSWORD

# add check that pod keycloak-cnpg-1 is running in namespace keycloak before proceeding
export PGPASSWORD=KEYCLOAK_DB_PASSWORD
psql -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak < $KEYCLOAK_DB_FILE
unset PGPASSWORD