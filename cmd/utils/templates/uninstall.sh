#!/bin/bash

# Function to delete a YAML file
action_delete_file() {
  local file="$1"
  echo "Deleting resources from file: $file"
  kubectl delete -f "$file" --ignore-not-found
}

# Function to patch finalizers from objects difficult to delete
patch_finalizers() {
  local object="$1"
  echo "Patching $object to remove finalizer and allow delete to complete"
  kubectl patch $object -p '{"metadata":{"finalizers":[]}}' --type=merge
}

# Patch objects with hanging finalizers
handle_hanging_objects(){
  local object
  patch_objects=$(kubectl get objects --no-headers -o name)
  for object in ${patch_objects}; do
    patch_finalizers $object
    #kubectl delete $object --ignore-not-found
  done
}

# Main function to uninstall the stack
uninstall_stack_logic() {
  local stack_path="$1"
  echo "Uninstalling stack from: $stack_path"

  # Delete stack YAML file
  action_delete_file "$stack_path/stack.yaml"

  # sleep for 60 just in case
  echo "Sleeping for 60 seconds to allow things to spin down"
  sleep 60

  handle_hanging_objects

  echo "Uninstallation complete!"
}

# Entry point
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <stack_path>"
  exit 1
fi

uninstall_stack_logic "$1"
