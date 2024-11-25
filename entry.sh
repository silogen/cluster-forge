#!/bin/sh

TASK=$1
shift # Shift the arguments to remove the first one (TASK)

case "$TASK" in
  forge)
    echo "Executing forge"
    /usr/local/bin/forge "$@"
    ;;
    echo "Unknown task: $TASK"
    exit 1
    ;;
esac
