#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

export BYO_DB=false
export BYO_S3=false
export BYO_GW=false

"${SCRIPT_DIR}/install_base.sh"

if [[ ${BYO_DB} == true ]]; then
  "${SCRIPT_DIR}/db.sh"
fi

if [[ ${BYO_S3} == true ]]; then
  "${SCRIPT_DIR}/s3.sh"
fi

if [[ ${BYO_S3} == true ]]; then
  "${SCRIPT_DIR}/gateway.sh"
fi