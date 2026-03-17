#!/bin/bash

# patch the airm-cnpg with finalizer annotation

# first find which db is the primart in the case of replicas > 1
# check for pod with label cnpg.io/instanceRole: primary
CNPG_POD_NAME=$(kubectl get pods -n airm -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl patch "$CNPG_POD_NAME" -n airm --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io/airm-cnpg"]}}'

ARGO_INITIAL_ADMIN=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo)

# Login to ArgoCD
kubectl exec -it -n argocd $(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}') \
  -- argocd login localhost:8080 --username admin --password ${ARGO_INITIAL_ADMIN} --insecure

# Set sync policy to none for both applications
argocd app set cluster-forge --sync-policy none --source-position 1
argocd app set airm --sync-policy none --source-position 1

# do a delete so the db stays in place
argocd app delete airm --cascade=false