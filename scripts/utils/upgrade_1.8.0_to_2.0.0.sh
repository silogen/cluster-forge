#!/bin/bash

# exit early on error, treat unset vars as errors, enable debug output, and fail if any command in a pipeline fails
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# export AIRM CNPG DB and RabbitMQ data before deleting the applications
BACKUP_DIR="/tmp/backups"
mkdir -p "$BACKUP_DIR"
echo "Exporting AIRM CNPG DB and RabbitMQ data to $BACKUP_DIR..."
OUTPUT=$("$SCRIPT_DIR/export_databases.sh" "$BACKUP_DIR")
echo "$OUTPUT"  # show progress to user
AIRM_DB_EXPORT_FILE=$(echo "$OUTPUT" | grep '^EXPORT_AIRM_FILE:' | cut -d: -f2-)

# export RabbitMQ data
echo "Exporting RabbitMQ data..."
OUTPUT=$("$SCRIPT_DIR/export_rabbitmq.sh" "$BACKUP_DIR")
echo "$OUTPUT"
RMQ_EXPORT_FILE=$(echo "$OUTPUT" | grep '^EXPORT_RMQ_FILE:' | cut -d: -f2-)

ARGO_INITIAL_ADMIN=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo)
ARGO_POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd "$ARGO_POD" -- sh -c "
  argocd login localhost:8080 --username admin --password '${ARGO_INITIAL_ADMIN}' --plaintext &&  
  argocd app set cluster-forge --sync-policy none --source-position 1
  for app in aim-cluster-model-source kaiwo kaiwo-crds kaiwo-config airm aiwb; do
    argocd app get \$app &>/dev/null && \
    argocd app set \$app --sync-policy none --source-position 1 && \
    argocd app delete \$app --cascade=true || true
  done
"

# message about the need to remove finalizers
cat <<'EOF'
================
*** You need to manually remove a finalizer from any stuck resource in the airm namespace ***

You can do this with the following example command:
kubectl patch <resource_type>/<resource_name> -n airm --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true

Waiting for ArgoCD applications to be deleted (15 min timeout)...
EOF

kubectl wait applications.argoproj.io -n argocd --for=delete --timeout=900s \
  aim-cluster-model-source airm kaiwo kaiwo-crds kaiwo-config

kubectl delete aimclustermodel.aim.silogen.ai --all -A
kubectl delete aimclustermodelsource.aim.silogen.ai --all -A
kubectl delete aimclusterservicetemplates.aim.silogen.ai --all -A

# manually delete AIRM secrets that will be recreated by the new app
kubectl delete secret/airm-tls-secret -n airm --ignore-not-found=true
kubectl delete secret/airm-rabbitmq-common-vhost-user -n airm --ignore-not-found=true

envsubst '$SCRIPT_DIR $AIRM_DB_EXPORT_FILE $RMQ_EXPORT_FILE' <<'EOF'
All applications deleted, proceed with upgrade:

# # # Gitea cluster-values/values.yaml: 
- ensure your list of enabled apps is in sync with the root/<size>_values.yaml appropriate for your global.clusterSize
- comment out 'airm' from the list of enabled apps (to create a window for importing the AIRM DB and RabbitMQ data) 
- update global.targetRevision to v2.0.0 or v2.0.0-rcX
- add helmParameters for airm and aiwb if installing a release candidate

# # #  ArgoCD web UI:
- update cluster-forge parent app in Gitea to match Gitea global.targetRevision
- enable cluster-forge auto-sync (disabled by this script)
- refresh the cluster-forge app in ArgoCD
- wait for the airm-infra-components app to be healthy and synced before proceeding

# # # Shell
- run the import scripts to restore the AIRM DB and RabbitMQ data:
  - $SCRIPT_DIR/import_databases.sh "$AIRM_DB_EXPORT_FILE"
  - $SCRIPT_DIR/import_rabbitmq.sh "$RMQ_EXPORT_FILE"

# # # Gitea cluster-values/values.yaml:
- uncomment 'airm' in the list of enabled apps to redeploy AIRM with the restored data

# # # ArgoCD web UI:
- sync the cluster-forge app to deploy AIRM with the restored data

# # # Keycloak:
- open browser to kc.<domain>
- user: silogen-admin with password from secret keycloak/keycloak-credentials
- change to realm AIRM
- click 'Clients' and edit first entry (354a0fa1-35ac-4a6d-9c4d-d661129c2cd0)
- add valid redirect URIs:
  - https://aiwbapi.<domain>/*
  - https://aiwbui.<domain>/* 

# # # Validate
- login to https://airmui.<domain> with devuser@<domain>, password from secret airm/airm-user-credentials
- login to https://aiwbui.<domain>