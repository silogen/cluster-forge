#!/bin/bash
#
# upgrade_1.8.0_to_2.0.0.sh — Assisted migration from cluster-forge pre v2.0.0 to v2.0.0
#
# DISCLAIMER: This is an example script only. Adjust paths and commands as needed
# for your system. This is not officially supported. Always test in a safe
# environment before running in production.
#
# What this script does:
#   1. Exports AIRM CNPG database data to /tmp/backups/ via export_databases.sh
#   2. Exports RabbitMQ data to /tmp/backups/ via export_rabbitmq.sh
#   3. Logs into ArgoCD and disables auto-sync on cluster-forge
#   4. Disables auto-sync and cascade-deletes: aim-cluster-model-source, kaiwo,
#      kaiwo-crds, kaiwo-config, airm, aiwb
#   5. Waits for all deleted applications to be fully removed (15 min timeout)
#   6. Deletes all aimclustermodel, aimclustermodelsource, and
#      aimclusterservicetemplates resources cluster-wide
#   7. Deletes AIRM secrets that will be recreated by the new app version
#   8. Prints the remaining manual steps (Gitea, ArgoCD, import, Keycloak)
#                            
#                                                                                                 
###################################################################################################

# exit early on error, treat unset vars as errors, enable debug output, and fail if any command in a pipeline fails
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# export AIRM CNPG DB and RabbitMQ data before deleting the applications
BACKUP_DIR="/tmp/backups"
mkdir -p "$BACKUP_DIR"
echo "Exporting AIRM CNPG DB and RabbitMQ data to $BACKUP_DIR..."
OUTPUT=$("$SCRIPT_DIR/export_databases.sh" "$BACKUP_DIR" --airm)
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
  aim-cluster-model-source kaiwo kaiwo-crds kaiwo-config airm aiwb

kubectl delete aimclustermodel.aim.silogen.ai --all -A
kubectl delete aimclustermodelsource.aim.silogen.ai --all -A
kubectl delete aimclusterservicetemplates.aim.silogen.ai --all -A

echo "All applications deleted, proceed with upgrade."
echo ""
DOC="$SCRIPT_DIR/../../docs/upgrade_to_v2.0.0.md"
if [[ -f "$DOC" ]]; then
  cat "$DOC"
else
  echo "for next steps, refer to the documentation at: https://github.com/silogen/cluster-forge/blob/main/docs/upgrade_to_v2.0.0.md"
fi
echo ""
echo "Resolved import commands for this run:"
echo "  $SCRIPT_DIR/import_databases.sh \"$AIRM_DB_EXPORT_FILE\""
echo "  $SCRIPT_DIR/import_rabbitmq.sh \"$RMQ_EXPORT_FILE\""
