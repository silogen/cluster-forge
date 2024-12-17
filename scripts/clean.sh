#!/bin/bash

for dir in "working"/*; do
  if [ -d "$dir" ] && [ "$(basename "$dir")" != "pre" ]; then
    rm -rf "$dir"
  fi
done

rm -rf working/*.yaml
rm -rf working/pre/*.yaml
rm -rf output/*.yaml
rm -rf output/*.yml
rm -rf stacks/*.yaml
rm -rf Library
rm -rf logs/app.log
