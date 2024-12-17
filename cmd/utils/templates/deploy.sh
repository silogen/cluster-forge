#!/bin/bash

# Function to apply a YAML file
action_apply_file() {
  local file="$1"
  echo "Applying file: $file"
  kubectl apply -f "$file"
}

# Function to wait for a CRD
wait_for_crd() {
  local crd_name="$1"
  echo "Waiting for CRD: $crd_name to become available..."

  # Loop until the CRD is found and Established condition is True
  until kubectl get crd "$crd_name" &> /dev/null && \
        kubectl wait --for=condition=Established crd/"$crd_name" --timeout=60s &> /dev/null; do
    echo "CRD $crd_name is not ready. Retrying in 5 seconds..."
    sleep 5
  done

  echo "CRD $crd_name is now ready!"
}

# Main function to deploy the stack
deploy_stack_logic() {
  local stack_path="$1"
  echo "Deploying stack from: $stack_path"

  # Apply base Crossplane YAML
  action_apply_file "$stack_path/crossplane_base.yaml"

  # List of required CRDs
  required_crds=(
    "providers.pkg.crossplane.io"
    "functions.pkg.crossplane.io"
    "deploymentruntimeconfigs.pkg.crossplane.io"
    "compositions.apiextensions.crossplane.io"
    "compositeresourcedefinitions.apiextensions.crossplane.io"
  )

  # Wait for each required CRD
  for crd in "${required_crds[@]}"; do
    wait_for_crd "$crd" || { echo "Failed to wait for CRD $crd"; exit 1; }
  done

  # Apply Crossplane and provider YAML files
  action_apply_file "$stack_path/crossplane.yaml"
  kubectl wait --for=condition=Healthy providers/provider-kubernetes --timeout=60s
  action_apply_file "$stack_path/crossplane_provider.yaml"

  # Apply composition YAML file
  action_apply_file "$stack_path/composition.yaml"

  # Restart Crossplane pods and wait for readiness
  echo "Restarting Crossplane pods..."
  kubectl delete pods --all -n crossplane-system
  kubectl wait --for=condition=Ready --timeout=600s pods --all -n crossplane-system

  # Apply stack YAML file
  action_apply_file "$stack_path/stack.yaml"

  echo "Deployment complete!"
}

# Entry point
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <stack_path>"
  exit 1
fi

deploy_stack_logic "$1"
