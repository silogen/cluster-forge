#!/bin/bash
set -e

NAMESPACE=argocd

# Wait for namespace to exist
until kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; do
  echo "Waiting for namespace $NAMESPACE to be created..."
  sleep 2
done

# Only create the secret if it doesn't already exist
if ! kubectl get secret argocd-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  SECRET_KEY=$(head -c 32 /dev/urandom | base64)
  kubectl create secret generic argocd-secret \
    --from-literal=server.secretkey="$SECRET_KEY" \
    -n "$NAMESPACE"
  echo "argocd-secret created in namespace $NAMESPACE."
else
  echo "argocd-secret already exists in namespace $NAMESPACE, skipping creation."
fi