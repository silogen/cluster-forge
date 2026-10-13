#!/usr/bin/env bash
# The AIM model catalog.
#
# The AIM engine serves a model that an AIMClusterModel describes. The engine
# creates no AIMClusterModel itself: an AIMClusterModelSource names the model
# images, and the engine runs a discovery Job on each one. cluster-forge
# installs these objects from the chart sources/aim-cluster-model-source. The
# helm-only instructions do not install that chart, so the catalog stays empty
# and AI Workbench offers no model.
#
# AIM_MODEL_IMAGES gives the model images. AIM_BASE_IMAGES gives the base images
# that AI Workbench uses to onboard a custom model. Each image starts one
# discovery Job that pulls a large image, so the default list is short.
#
# A model with a gated source repository needs a HuggingFace token. The default
# list holds models with no gate.
#
# Run this script after deps/compute.sh, which installs the AIM engine.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AIM_MODEL_IMAGES="${AIM_MODEL_IMAGES:-amdenterpriseai/aim-openai-gpt-oss-20b:0.11.1}"
AIM_BASE_IMAGES="${AIM_BASE_IMAGES:-amdenterpriseai/aim-base:0.13.1}"
AIM_CATALOG_REGISTRY="${AIM_CATALOG_REGISTRY:-docker.io}"
AIM_CATALOG_MAX_MODELS="${AIM_CATALOG_MAX_MODELS:-25}"

yaml_list() {
  local prefix="$1" images="$2" item
  for item in ${images}; do
    printf '%s%s\n' "${prefix}" "${item}"
  done
}

kubectl apply --filename - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModelSource
metadata:
  name: aim-base-models
spec:
  images:
$(yaml_list '  - ' "${AIM_BASE_IMAGES}")
  maxModels: ${AIM_CATALOG_MAX_MODELS}
  registry: ${AIM_CATALOG_REGISTRY}
  syncInterval: 1h
EOF

kubectl apply --filename - <<EOF
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModelSource
metadata:
  name: aim-models
spec:
  filters:
$(yaml_list '    - image: ' "${AIM_MODEL_IMAGES}")
  maxModels: ${AIM_CATALOG_MAX_MODELS}
  registry: ${AIM_CATALOG_REGISTRY}
  syncInterval: 1h
EOF

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
