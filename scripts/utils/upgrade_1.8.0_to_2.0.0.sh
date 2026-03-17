#!/bin/bash

# patch the airm-cnpg with finalizer annotation

# first find which db is the primart in the case of replicas > 1
# check for pod with label cnpg.io/instanceRole: primary
CNPG_POD_NAME=$(kubectl get pods -n airm -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl patch "$CNPG_POD_NAME" -n airm --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io/airm-cnpg"]}}'

ARGO_INITIAL_ADMIN=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo)

ARGO_POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd "$ARGO_POD" -- sh -c "
  argocd login localhost:8080 --username admin --password '${ARGO_INITIAL_ADMIN}' --insecure &&
  argocd app set cluster-forge --sync-policy none --source-position 1 &&
  argocd app set airm --sync-policy none --source-position 1 &&
  argocd app delete airm --cascade=false
"