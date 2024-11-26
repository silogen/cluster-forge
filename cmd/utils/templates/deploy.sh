#!/bin/bash

kubectl apply -f crossplane_base.yaml
kubectl wait --for=condition=available --timeout=600s deployments --all -n crossplane-system
DIRECTORY=$PWD

# Loop through all YAML files in the directory that start with namespace
for file in "$DIRECTORY"/namespace*.yaml; do
  if [ -f "$file" ]; then
    echo "Applying $file"
    kubectl apply --server-side -f "$file"
  fi
done
# Loop through all YAML files in the directory that start with crd
for file in "$DIRECTORY"/crd*.yaml; do
  if [ -f "$file" ]; then
    echo "Applying $file"
    kubectl apply --server-side -f "$file"
  fi
done
# Loop through all YAML files in the directory that start with cm_
for file in "$DIRECTORY"/cm*.yaml; do
  if [ -f "$file" ]; then
    echo "Applying $file"
    kubectl apply --server-side -f "$file"
  fi
done

kubectl apply -f crossplane.yaml
sleep 20
kubectl apply -f function-templates.yaml
kubectl apply -f crossplane_provider.yaml
kubectl apply -f composition.yaml
kubectl delete pods --all -n crossplane-system
kubectl wait --for=condition=Ready --timeout=600s pods --all -n crossplane-system
kubectl apply -f stack.yaml

echo "Stack Deployed!"

