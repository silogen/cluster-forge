#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

export PLUGGABLE_DB=false
export PLUGGABLE_S3=false
export PLUGGABLE_GW=false

"${SCRIPT_DIR}/install_base.sh" "$@"

if [[ ${PLUGGABLE_DB} == true ]]; then
  "${SCRIPT_DIR}/db.sh"
fi

if [[ ${PLUGGABLE_S3} == true ]]; then
  "${SCRIPT_DIR}/s3.sh"
fi

if [[ ${PLUGGABLE_GW} == true ]]; then
  "${SCRIPT_DIR}/gateway.sh"
fi
