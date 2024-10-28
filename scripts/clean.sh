#!/bin/bash

for dir in "working"/*; do
  if [ -d "$dir" ] && [ "$(basename "$dir")" != "pre" ]; then
    echo "Deleting directory: $dir"
    rm -rf "$dir"
  fi
done

rm -rf working/*.yaml
rm -rf output/*.yaml
rm -rf output/*.yml
rm -rf Library
rm -rf logs/app.log
