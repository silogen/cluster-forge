#!/bin/bash

echo "WARNING: This script will delete the airm ArgoCD application."
echo "Please ensure the airm-cnpg database has been backed up before proceeding."
echo ""
read -r -p "Has the airm CNPG database been backed up? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborting. Please back up the database before running this script."
  exit 1
fi

ARGO_INITIAL_ADMIN=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo)

ARGO_POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd "$ARGO_POD" -- sh -c "
  argocd login localhost:8080 --username admin --password '${ARGO_INITIAL_ADMIN}' --plaintext &&
  argocd app set cluster-forge --sync-policy none --source-position 1 &&
  argocd app set airm --sync-policy none --source-position 1 &&
  argocd app delete airm --cascade=true
"
