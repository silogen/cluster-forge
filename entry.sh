#!/bin/sh

TASK=$1
shift # Shift the arguments to remove the first one (TASK)

case "$TASK" in
  forge)
    echo "Executing forge"
    /usr/local/bin/forge "$@"
    ;;
  kubectl)
    echo "Executing kubectl"
    /usr/local/bin/kubectl "$@"
    ;;
  pods)
    echo "Executing pods"
    /usr/local/bin/kubectl get pods "$@"
    ;;
  *)
    echo "Unknown task: $TASK"
    exit 1
    ;;
esac