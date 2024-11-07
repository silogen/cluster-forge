
#!/bin/bash

kubectl apply -f crossplane_base.yaml
kubectl wait --for=condition=available --timeout=600s deployments --all
DIRECTORY=$PWD

# Loop through all YAML files in the directory that start with cm_
for file in "$DIRECTORY"/cm_*.yaml; do
  if [ -f "$file" ]; then
    echo "Applying $file"
    kubectl apply -f "$file"
  else
    echo "No files matching cm_*.yaml found in $DIRECTORY"
  fi
done

kubectl apply -f crossplane.yaml
kubectl wait --for=condition=available --timeout=600s pods --all
kubectl apply -f crossplane_provider.yaml
kubectl apply -f composition.yaml
kubectl delete pods --all -n crossplane-system
kubectl wait --for=condition=available --timeout=600s pods --all
kubectl apply -f claim.yaml