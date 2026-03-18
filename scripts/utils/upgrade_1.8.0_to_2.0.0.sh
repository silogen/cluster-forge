#!/bin/bash +x

# exit early on error
set -e

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
  argocd app set cluster-forge --sync-policy none --source-position 1
  for app in aim-cluster-model-source kaiwo kaiwo-crds kaiwo-config airm aiwb; do
    argocd app get \$app &>/dev/null && \
    argocd app set \$app --sync-policy none --source-position 1 && \
    argocd app delete \$app --cascade=true || true
  done
"

# wait for the applications to be deleted before proceeding
echo "Waiting for ArgoCD applications to be deleted..."
kubectl wait applications.argoproj.io -n argocd --for=delete --timeout=300s \
  aim-cluster-model-source airm kaiwo kaiwo-crds kaiwo-config

kubectl delete aimclustermodel.aim.silogen.ai --all -A
kubectl delete aimclustermodelsource.aim.silogen.ai --all -A
kubectl delete aimclusterservicetemplates.aim.silogen.ai --all -A

# manually delete AIRM secrets that will be recreated by the new app
kubectl delete secret/airm-tls-secret -n airm --ignore-not-found=true
kubectl delete secret/airm-rabbitmq-common-vhost-user -n airm --ignore-not-found=true

# remove finalizer