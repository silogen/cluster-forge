#!/usr/bin/env bash
# Section 3: pack the complete EAI haul in Cluster-Forge install order.
# Run from anywhere; the script cds to its own directory.
#
# Official README path is all-model-images (3.43 uses --add-images).
# For a smaller test haul, use none-model-images and optional image refs.
#
#   ./hauler.sh
#   ./hauler.sh all-model-images
#   ./hauler.sh none-model-images
#   ./hauler.sh none-model-images amdenterpriseai/aim-qwen-qwen3-32b:0.13.0
#   ./hauler.sh none-model-images --skip-transfer -- amdenterpriseai/aim-google-gemma-3-1b-it:0.12.0
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
export EAI_STORE=haul/eai-store

MODEL_IMAGES=all
SKIP_TRANSFER=0
AIM_IMAGES=()

usage() {
  cat <<'EOF'
Usage: hauler.sh [all-model-images|none-model-images] [--skip-transfer] [image ...]

  all-model-images   3.43: pack the AIM catalog chart and all discovered
                     model images (--add-images). This is the README path.
  none-model-images  3.43: pack the AIM catalog chart only. Extra arguments
                     are hauled with hauler store add image (nothing else).
  --skip-transfer    Skip 3.45 rsync (use when packing on the isolated host).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    all-model-images|--all-model-images|--model-images=all)
      MODEL_IMAGES=all
      shift
      ;;
    none-model-images|--none-model-images|--model-images=none)
      MODEL_IMAGES=none
      shift
      ;;
    --skip-transfer)
      SKIP_TRANSFER=1
      shift
      ;;
    --)
      shift
      AIM_IMAGES+=("$@")
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      AIM_IMAGES+=("$1")
      shift
      ;;
  esac
done

if [[ "$MODEL_IMAGES" == all && ${#AIM_IMAGES[@]} -gt 0 ]]; then
  echo "all-model-images does not take extra image arguments" >&2
  exit 1
fi

# Prefer PATH, then a bundled linux/amd64 binary next to this script, then
# the official Linux installer (https://get.hauler.dev).
ensure_hauler() {
  if command -v hauler >/dev/null 2>&1; then
    echo "using hauler $(command -v hauler)"
    return 0
  fi
  if [[ -x ./haul/hauler ]]; then
    export PATH="$(pwd)/haul:${PATH}"
    echo "using bundled hauler $(command -v hauler)"
    return 0
  fi
  echo "hauler not on PATH; installing with https://get.hauler.dev"
  local dest="${HAULER_INSTALL_DIR:-$HOME/.local/bin}"
  mkdir -p "$dest"
  curl -sfL https://get.hauler.dev | HAULER_INSTALL_DIR="$dest" bash
  export PATH="${dest}:${PATH}"
  if ! command -v hauler >/dev/null 2>&1; then
    echo "hauler install finished but the binary is not on PATH (tried ${dest})" >&2
    exit 1
  fi
  echo "using hauler $(command -v hauler)"
}

ensure_hauler

# Several Cluster-Forge steps are neither a chart nor a file on disk: their
# manifests are inline extraObjects in values-openshift.yaml, and install.sh
# applies them straight from there. Nothing was hauling them, so the
# disconnected side had no way to run those steps at all.
#
# They are rendered to files here, at pack time, rather than taught to
# dehauler.sh: the values file and the scripts it references only exist on this
# side of the gap, and rendering here keeps the disconnected side needing
# nothing but the store. ${VAR} references are left intact on purpose --
# domains and access keys belong to the deployment, so dehauler.sh expands them.
CF_VALUES=haul/cluster-forge/root/values-openshift.yaml
OBJECTS_DIR=haul/objects

OBJECT_APPS=(
  aiwb-infra
  aiwb-infra-cnpg-secrets
  aiwb-infra-db-secrets
  cluster-auth-shim
  seaweedfs-secrets
  minio-external-redirect
)

render_objects() {
  command -v yq >/dev/null 2>&1 || {
    echo "yq is required to render the inline extraObjects steps" >&2
    exit 1
  }
  mkdir -p "$OBJECTS_DIR"
  local app out
  for app in "${OBJECT_APPS[@]}"; do
    out="${OBJECTS_DIR}/objects-${app}.yaml"
    : >"$out"
    # cluster-auth-shim is the one objects step that also declares configMaps:,
    # a ConfigMap built out of a script in the repository. kubectl renders it
    # rather than a here-doc because the script has to survive as a block
    # scalar with its own indentation intact.
    if [[ "$app" == cluster-auth-shim ]]; then
      kubectl create configmap cluster-auth-shim \
        --namespace cluster-auth \
        --from-file=shim.py=haul/cluster-forge/docs/manual_helm_install/scripts/cluster-auth-shim.py \
        --dry-run=client -o yaml >>"$out"
      echo '---' >>"$out"
    fi
    yq -r ".apps.\"${app}\".extraObjects" "$CF_VALUES" >>"$out"
    echo "rendered ${out}"
  done
}

render_objects

# 3.1 Kuberay operator
hauler store add chart haul/cluster-forge/sources/kuberay-operator/1.4.2 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.2 CloudNativePG operator (PLUGGABLE_DB=false)
hauler store add chart haul/cluster-forge/sources/cnpg-operator/0.26.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Cluster CRs pull these postgres images; the operator chart --add-images does not.
hauler store add image ghcr.io/cloudnative-pg/postgresql:17 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image ghcr.io/cloudnative-pg/postgresql:17.2 --platform linux/amd64 --store "$EAI_STORE"

# 3.3 AppWrapper
hauler store add file haul/cluster-forge/sources/appwrapper/v1.1.2/install.yaml --name appwrapper-install.yaml --store "$EAI_STORE"
hauler store add image quay.io/ibm/appwrapper:v1.1.2 --platform linux/amd64 --store "$EAI_STORE"

# 3.4 Kyverno
hauler store add chart haul/cluster-forge/sources/kyverno/3.5.1 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Chart pods name reg.kyverno.io, which rewrite_images must map onto this store path.
hauler store add image reg.kyverno.io/kyverno/kyverno:v1.15.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image reg.kyverno.io/kyverno/kyvernopre:v1.15.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image reg.kyverno.io/kyverno/background-controller:v1.15.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image reg.kyverno.io/kyverno/cleanup-controller:v1.15.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image reg.kyverno.io/kyverno/reports-controller:v1.15.1 --platform linux/amd64 --store "$EAI_STORE"

# 3.5 Kyverno base policies
hauler store add chart haul/cluster-forge/sources/kyverno-policies/base --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.6 Kyverno local-path storage policies
hauler store add chart haul/cluster-forge/sources/kyverno-policies/storage-local-path --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# The step declares extraManifests as well as a chart, and the policy that
# scopes local-path to ReadWriteOnce is only in the manifest.
hauler store add file haul/cluster-forge/docs/openshift/extra/04-local-path-access-mode-scoped.yaml --name 04-local-path-access-mode-scoped.yaml --store "$EAI_STORE"

# 3.7 Prometheus operator CRDs
hauler store add chart haul/cluster-forge/sources/prometheus-operator-crds/23.0.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.8 cert-manager
hauler store add chart haul/cluster-forge/sources/cert-manager/v1.18.2 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.9 OpenTelemetry operator
hauler store add chart haul/cluster-forge/sources/opentelemetry-operator/0.93.1 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# AIM Engine metrics collector uses this tag; the operator chart hauls contrib, not k8s.
hauler store add image ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:0.131.1 --platform linux/amd64 --store "$EAI_STORE"

# 3.9b MetalLB. Cluster-Forge ships the upstream native manifest rather than
# a Helm chart; its controller and speaker images therefore have to be added
# explicitly. The disconnected side creates the deployment-specific L2 pool.
hauler store add file haul/cluster-forge/sources/metallb/v0.15.2/metallb-native.yaml --name metallb-native.yaml --store "$EAI_STORE"
hauler store add image quay.io/metallb/controller:v0.15.2 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image quay.io/metallb/speaker:v0.15.2 --platform linux/amd64 --store "$EAI_STORE"

# 3.10 External Secrets operator
hauler store add chart haul/cluster-forge/sources/external-secrets/0.19.2 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Pods name oci.external-secrets.io, not docker.io; keep that host in the store.
hauler store add image oci.external-secrets.io/external-secrets/external-secrets:v0.19.2 --platform linux/amd64 --store "$EAI_STORE"

# 3.11 Gateway API and Envoy Gateway CRDs (source bundle is v1.8.1)
hauler store add chart haul/cluster-forge/sources/envoy-gateway/v1.8.1/charts/crds --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.12 OpenBao
hauler store add chart haul/cluster-forge/sources/openbao/0.18.2 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.13 OpenBao configuration
hauler store add chart haul/cluster-forge/sources/openbao-config/0.1.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.14 OpenBao initialization job
hauler store add chart haul/cluster-forge/sources/openbao-init-job/0.1.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.15 External Secrets configuration
hauler store add file haul/cluster-forge/sources/external-secrets-config/openbao-secret-store.yaml --name external-secrets-openbao-secret-store.yaml --store "$EAI_STORE"

# 3.16 OpenTelemetry LGTM stack
hauler store add chart haul/cluster-forge/sources/otel-lgtm-stack/v1.0.7 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Grafana-dashboard init Job; --add-images on this chart does not haul it.
hauler store add image docker.io/curlimages/curl:8.8.0 --platform linux/amd64 --store "$EAI_STORE"

# 3.17 KEDA
hauler store add chart haul/cluster-forge/sources/keda/2.18.1 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.18 Kedify OpenTelemetry scaler
hauler store add chart haul/cluster-forge/sources/kedify-otel/v0.0.6 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Sidecar collector is otel/…:0.114.0, not the k8s collector hauled with the OTel operator.
hauler store add image docker.io/otel/opentelemetry-collector-k8s:0.114.0 --platform linux/amd64 --store "$EAI_STORE"

# 3.18b AI gateway base objects (Gateway, GatewayClass, backend TLS policy)
hauler store add file haul/cluster-forge/docs/openshift/extra/06-ai-gateway.yaml --name 06-ai-gateway.yaml --store "$EAI_STORE"

# 3.19 Inference Extension CRDs
hauler store add chart haul/cluster-forge/sources/inference-extension-crds/v1.5.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.20 Envoy AI Gateway CRDs
hauler store add chart haul/cluster-forge/sources/envoy-ai-gateway-crds/v1.0.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.21 Envoy Gateway
hauler store add chart haul/cluster-forge/sources/envoy-gateway/v1.8.1 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# Data-plane pods are created by the controller, not by helm template --add-images.
hauler store add image docker.io/envoyproxy/envoy:distroless-v1.38.1 --platform linux/amd64 --store "$EAI_STORE"

# 3.22 Envoy AI Gateway
hauler store add chart haul/cluster-forge/sources/envoy-ai-gateway/v1.0.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.23 Envoy Gateway configuration
hauler store add chart haul/cluster-forge/sources/envoy-gateway-config --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.23b AI gateway webhook health probe. A script rather than a manifest: the
# step reads the webhook's caBundle back and re-syncs it from the controller
# TLS secret, which no manifest can express.
hauler store add file haul/cluster-forge/scripts/ai-gateway-webhook-health.sh --name ai-gateway-webhook-health.sh --store "$EAI_STORE"

# 3.24 KServe CRDs
hauler store add chart haul/cluster-forge/sources/kserve-crds/v0.16.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.25 KServe
hauler store add chart haul/cluster-forge/sources/kserve/v0.16.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/kserve/kserve-controller:v0.16.0 --platform linux/amd64 --store "$EAI_STORE"

# 3.26 AMD GPU Operator and CRDs
hauler store add chart haul/cluster-forge/sources/amd-gpu-operator/v1.4.1 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.27 AMD GPU Operator configuration (no --add-images: skip imageregistry.io placeholder)
hauler store add chart haul/cluster-forge/sources/amd-gpu-operator-config/v1.4.1 --repo . --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/rocm/device-metrics-exporter:v1.4.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/rocm/device-config-manager:v1.4.1 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/rocm/test-runner:v1.4.1 --platform linux/amd64 --store "$EAI_STORE"

# 3.27b AMD GPU NodeFeatureRule
hauler store add file haul/cluster-forge/docs/openshift/extra/08-amd-gpu-nodefeaturerule.yaml --name 08-amd-gpu-nodefeaturerule.yaml --store "$EAI_STORE"

# 3.28 AIM Engine CRDs
hauler store add chart aim-engine-crds-chart --repo oci://registry-1.docker.io/amdenterpriseai --version 0.2.5 --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.29 AIM Engine
hauler store add chart aim-engine-chart --repo oci://registry-1.docker.io/amdenterpriseai --version 0.2.5 --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.29b AI Workbench base objects: namespaces, Keycloak and MinIO secrets, and
# the database credentials in whichever shape the deployment uses. Rendered
# above from values-openshift.yaml, ${VAR} references still unexpanded.
hauler store add file haul/objects/objects-aiwb-infra.yaml --name objects-aiwb-infra.yaml --store "$EAI_STORE"
hauler store add file haul/objects/objects-aiwb-infra-cnpg-secrets.yaml --name objects-aiwb-infra-cnpg-secrets.yaml --store "$EAI_STORE"
hauler store add file haul/objects/objects-aiwb-infra-db-secrets.yaml --name objects-aiwb-infra-db-secrets.yaml --store "$EAI_STORE"
hauler store add file haul/objects/objects-cluster-auth-shim.yaml --name objects-cluster-auth-shim.yaml --store "$EAI_STORE"
# The shim is a stock python image running the mounted script, so the only
# image it needs is python itself.
hauler store add image docker.io/library/python:3.11-slim --platform linux/amd64 --store "$EAI_STORE"

# 3.30 AI Workbench CNPG infrastructure (PLUGGABLE_DB=false)
hauler store add chart aiwb-cnpg-chart --repo oci://registry-1.docker.io/amdenterpriseai --version 2.0.0 --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.31 Keycloak
hauler store add chart haul/cluster-forge/sources/keycloak-old --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.32 SeaweedFS CRDs: 0.1.36 ships the Seaweed CRD inside the operator chart
# (crds.create), and sources/seaweedfs-crds/0.1.36 is only a deprecation stub.
# The standalone 0.1.13 CRD lacks .spec.s3, which seaweedfs-config renders.

# 3.33 SeaweedFS operator (PLUGGABLE_S3=false)
hauler store add chart haul/cluster-forge/sources/seaweedfs-operator/0.1.36 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# 0.1.36 still runs this operator tag; short name chrislusf/… is Docker Hub.
hauler store add image docker.io/chrislusf/seaweedfs-operator:1.0.33 --platform linux/amd64 --store "$EAI_STORE"

# 3.33b SeaweedFS S3 credentials (PLUGGABLE_S3=false)
hauler store add file haul/objects/objects-seaweedfs-secrets.yaml --name objects-seaweedfs-secrets.yaml --store "$EAI_STORE"

# 3.34 SeaweedFS configuration (PLUGGABLE_S3=false)
hauler store add chart haul/cluster-forge/sources/seaweedfs-config --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
# The Seaweed CR runs filer/master/s3/volume/admin from this image, not the operator tag.
hauler store add image docker.io/chrislusf/seaweedfs:4.40 --platform linux/amd64 --store "$EAI_STORE"

# 3.34b External MinIO redirect Service (PLUGGABLE_S3=true only, hauled either
# way so one store serves both shapes)
hauler store add file haul/objects/objects-minio-external-redirect.yaml --name objects-minio-external-redirect.yaml --store "$EAI_STORE"

# 3.35 AI Workbench
hauler store add chart aiwb-chart --repo oci://registry-1.docker.io/amdenterpriseai --version 2.0.0 --add-images --platform linux/amd64 --store "$EAI_STORE"
# Chart values use the short Docker Hub name amdenterpriseai/…, not registry-1.docker.io.
hauler store add image docker.io/amdenterpriseai/aiwb-api:2.0.0 --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/amdenterpriseai/aiwb-ui:2.0.0 --platform linux/amd64 --store "$EAI_STORE"

# 3.36 AI Gateway Discovery
hauler store add chart ai-gateway-discovery-chart --repo oci://registry-1.docker.io/amdenterpriseai --version 2.0.0 --add-images --platform linux/amd64 --store "$EAI_STORE"
hauler store add image docker.io/amdenterpriseai/ai-gateway-discovery:2.0.0 --platform linux/amd64 --store "$EAI_STORE"

# 3.37 RabbitMQ Cluster Operator
hauler store add file haul/cluster-forge/sources/rabbitmq/v2.15.0/cluster-operator.yml --name rabbitmq-cluster-operator.yaml --store "$EAI_STORE"
hauler store add image docker.io/rabbitmqoperator/cluster-operator:2.15.0 --platform linux/amd64 --store "$EAI_STORE"
# Node-label CronJob in default; ghcr.io is rewritten, but the chart --add-images never hauls it.
hauler store add image ghcr.io/silogen/kubectl:latest --platform linux/amd64 --store "$EAI_STORE"

# 3.38 Kueue
hauler store add chart haul/cluster-forge/sources/kueue/0.13.0 --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.39 Kueue configuration
hauler store add file haul/cluster-forge/sources/kueue-config/kueue-cluster-role-binding.yaml --name kueue-cluster-role-binding.yaml --store "$EAI_STORE"

# 3.40 Kaiwo CRDs
hauler store add chart kaiwo-crds-chart --repo oci://ghcr.io/silogen --version v0.2.1 --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.41 Kaiwo operator
hauler store add chart kaiwo-operator-chart --repo oci://ghcr.io/silogen --version v0.2.1 --add-images --platform linux/amd64 --store "$EAI_STORE"

# 3.42 Kaiwo configuration
hauler store add file haul/cluster-forge/sources/kaiwo-config/pvc-user-demo.yaml --name kaiwo-pvc-user-demo.yaml --store "$EAI_STORE"
hauler store add file haul/cluster-forge/sources/kaiwo-config/minio-credentials.yaml --name kaiwo-minio-credentials.yaml --store "$EAI_STORE"

# 3.43 AIM cluster model source
if [[ "$MODEL_IMAGES" == all ]]; then
  hauler store add chart haul/cluster-forge/sources/aim-cluster-model-source --repo . --add-images --platform linux/amd64 --store "$EAI_STORE"
else
  hauler store add chart haul/cluster-forge/sources/aim-cluster-model-source --repo . --platform linux/amd64 --store "$EAI_STORE"
  if [[ ${#AIM_IMAGES[@]} -gt 0 ]]; then
    for img in "${AIM_IMAGES[@]}"; do
      hauler store add image "$img" --platform linux/amd64 --store "$EAI_STORE"
    done
  fi
fi

# 3.44 is deployment-only (no haul commands)

# 3.45 Validate and save the complete haul
hauler store info --store "$EAI_STORE"
hauler store save --filename haul/eai-stack.tar.zst --store "$EAI_STORE"
cp "$(command -v hauler)" haul/hauler
cp dehauler.sh haul/dehauler.sh
tar -C haul -cf haul/eai-airgap.tar hauler dehauler.sh eai-stack.tar.zst
ls -lh haul/eai-stack.tar.zst haul/eai-airgap.tar
if [[ "$SKIP_TRANSFER" -eq 0 ]]; then
  rsync -ah --info=progress2 -e "ssh -o ProxyJump=none" haul/eai-airgap.tar ubuntu@132.145.131.234:~/
fi
