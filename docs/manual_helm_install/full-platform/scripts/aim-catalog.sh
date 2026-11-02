#!/usr/bin/env bash
# The AIM model catalog.
#
# Installs sources/aim-cluster-model-source from this repository. The chart
# creates the AIMClusterModelSource objects for AIM_HARDWARE_FAMILY. An empty
# value installs the unfiltered catalog. cpu installs no model source.
#
# Run this script after compute.sh, which installs the AIM engine.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# Writes a JSON array body, without the surrounding brackets, to stdout.
# Fails when a token is empty or is not an allowed family.
families_json() {
  local raw="$1" token trimmed json="" rest
  local -A seen=()
  local -a parts=()
  # Keep an empty field. `read` drops a trailing comma, and that comma is an error.
  rest="${raw}"
  while [[ "${rest}" == *","* ]]; do
    parts+=("${rest%%,*}")
    rest="${rest#*,}"
  done
  parts+=("${rest}")
  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "AIM_HARDWARE_FAMILY has an empty family name." >&2
    return 1
  fi
  for token in "${parts[@]}"; do
    trimmed="$(trim "${token}")"
    if [[ -z "${trimmed}" ]]; then
      echo "AIM_HARDWARE_FAMILY has an empty family name." >&2
      return 1
    fi
    case "${trimmed}" in
      cpu|epyc|instinct|radeon) ;;
      *)
        echo "AIM_HARDWARE_FAMILY has unknown family ${trimmed}." >&2
        echo "Allowed families: cpu, epyc, instinct, radeon." >&2
        return 1
        ;;
    esac
    [[ -n "${seen[${trimmed}]+x}" ]] && continue
    seen["${trimmed}"]=1
    if [[ -n "${json}" ]]; then
      json+=","
    fi
    json+="\"${trimmed}\""
  done
  printf '%s' "${json}"
}

family="$(trim "${AIM_HARDWARE_FAMILY:-}")"
json=""
if [[ -n "${family}" ]]; then
  json="$(families_json "${family}")"
fi

forge="$(forge_dir)"
chart="${forge}/sources/aim-cluster-model-source"
if [[ ! -f "${chart}/Chart.yaml" ]]; then
  echo "The chart sources/aim-cluster-model-source is absent in ${forge}." >&2
  exit 1
fi

helm_args=(
  upgrade --install aim-cluster-model-source "${chart}"
  --namespace aim-system --create-namespace
)
if [[ -n "${json}" ]]; then
  helm_args+=(--set-json "hardwareFamilies=[${json}]")
fi
helm "${helm_args[@]}" --wait --timeout 5m

if [[ "${json}" == '"cpu"' ]]; then
  echo "the cpu family installs no model source"
  exit 0
fi

sources="$(kubectl get aimclustermodelsource --no-headers 2>/dev/null | grep -c . || true)"
if [[ "${sources}" -eq 0 ]]; then
  echo "the catalog has no model source" >&2
  echo "check: kubectl get aimclustermodelsource" >&2
  exit 1
fi

# Discovery pulls each model image, so the first models appear minutes later.
# Wait for one AIMClusterModel, which shows that the engine reads the source.
AIM_CATALOG_TIMEOUT_SECONDS="${AIM_CATALOG_TIMEOUT_SECONDS:-900}"
deadline=$((SECONDS + AIM_CATALOG_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  ready="$(kubectl get aimclustermodels \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True' || true)"
  if [[ "${ready}" -gt 0 ]]; then
    echo "the catalog holds ${ready} ready model(s)"
    exit 0
  fi
  sleep 20
done

echo "no AIMClusterModel reported Ready after ${AIM_CATALOG_TIMEOUT_SECONDS}s." >&2
echo "check: kubectl get aimclustermodelsource,aimclustermodels" >&2
exit 1
