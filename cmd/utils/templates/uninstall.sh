#!/bin/bash

# Function to delete a YAML file
action_delete_file() {
  local file="$1"
  echo "Deleting resources from file: $file"
  kubectl delete -f "$file" --ignore-not-found
}

# Function to check if a CRD exists and delete it
wait_for_crd_deletion() {
  local crd_name="$1"
  echo "Waiting for CRD: $crd_name to be deleted..."

  # Loop until the CRD is deleted
  while kubectl get crd "$crd_name" &> /dev/null; do
    echo "CRD $crd_name still exists. Retrying in 5 seconds..."
    sleep 5
  done

  echo "CRD $crd_name has been deleted!"
}

# Main function to uninstall the stack
uninstall_stack_logic() {
  local stack_path="$1"
  echo "Uninstalling stack from: $stack_path"

  # Delete stack YAML file
  action_delete_file "$stack_path/stack.yaml"

  # Delete composition YAML file
  action_delete_file "$stack_path/composition.yaml"

  # Delete Crossplane provider YAML file
  action_delete_file "$stack_path/crossplane_provider.yaml"

  # Wait for Crossplane provider to be removed
  kubectl wait --for=delete providers/provider-kubernetes --timeout=60s || echo "Provider may already be deleted."

  # Delete Crossplane YAML files
  action_delete_file "$stack_path/crossplane.yaml"
  action_delete_file "$stack_path/crossplane_base.yaml"

  # List of required CRDs to delete
  required_crds=(
    "providers.pkg.crossplane.io"
    "functions.pkg.crossplane.io"
    "deploymentruntimeconfigs.pkg.crossplane.io"
    "compositions.apiextensions.crossplane.io"
    "compositeresourcedefinitions.apiextensions.crossplane.io"
  )

  # Delete each required CRD
  for crd in "${required_crds[@]}"; do
    echo "Deleting CRD: $crd"
    kubectl delete crd "$crd" --ignore-not-found
    wait_for_crd_deletion "$crd"
  done

  echo "Uninstallation complete!"
}

# Entry point
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <stack_path>"
  exit 1
fi

uninstall_stack_logic "$1"
