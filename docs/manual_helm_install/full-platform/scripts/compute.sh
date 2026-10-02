#!/usr/bin/env bash
# GPU operator v1.4.1, AppWrapper v1.1.2, Kueue 0.13.0,
# KubeRay 1.4.2, Kaiwo v0.2.1, KServe v0.16.0 Standard, AIM engine 0.2.6, KEDA 2.18.1.
# Kaiwo CRDs are applied with helm template (Helm release Secret limit).
# CLUSTER_NAME is the gpu-config label KUBE_CLUSTER_NAME. Default demo-cluster.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLUSTER_NAME="${CLUSTER_NAME:-demo-cluster}"
DRIVER_VERSION="${DRIVER_VERSION:-7.0}"
KSERVE_ATTEMPTS="${KSERVE_ATTEMPTS:-3}"
GPU_READY_TIMEOUT_SECONDS="${GPU_READY_TIMEOUT_SECONDS:-600}"

helm repo add --force-update rocm https://rocm.github.io/gpu-operator
helm repo add --force-update kuberay https://ray-project.github.io/kuberay-helm/
helm repo add --force-update kedacore https://kedacore.github.io/charts
helm repo update rocm kuberay kedacore

helm upgrade --install amd-gpu-operator rocm/gpu-operator-charts --version v1.4.1 \
  --namespace kube-amd-gpu --create-namespace \
  --set crds.defaultCR.install=false \
  --wait --timeout 8m

kubectl apply --filename - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gpu-config
  namespace: kube-amd-gpu
data:
  config.json: |
    {
      "GPUConfig": {
        "Fields": [
          "GPU_NODES_TOTAL", "GPU_PACKAGE_POWER", "GPU_AVERAGE_PACKAGE_POWER",
          "GPU_EDGE_TEMPERATURE", "GPU_JUNCTION_TEMPERATURE", "GPU_MEMORY_TEMPERATURE",
          "GPU_HBM_TEMPERATURE", "GPU_GFX_ACTIVITY", "GPU_UMC_ACTIVITY", "GPU_MMA_ACTIVITY",
          "GPU_VCN_ACTIVITY", "GPU_JPEG_ACTIVITY", "GPU_VOLTAGE", "GPU_GFX_VOLTAGE",
          "GPU_MEMORY_VOLTAGE", "PCIE_SPEED", "PCIE_MAX_SPEED", "PCIE_BANDWIDTH",
          "GPU_ENERGY_CONSUMED", "PCIE_REPLAY_COUNT", "PCIE_RECOVERY_COUNT",
          "PCIE_REPLAY_ROLLOVER_COUNT", "PCIE_NACK_SENT_COUNT", "PCIE_NAC_RECEIVED_COUNT",
          "GPU_CLOCK", "GPU_POWER_USAGE", "GPU_TOTAL_VRAM", "GPU_USED_VRAM", "GPU_FREE_VRAM",
          "GPU_TOTAL_VISIBLE_VRAM", "GPU_USED_VISIBLE_VRAM", "GPU_FREE_VISIBLE_VRAM",
          "GPU_TOTAL_GTT", "GPU_USED_GTT", "GPU_FREE_GTT",
          "GPU_ECC_CORRECT_TOTAL", "GPU_ECC_UNCORRECT_TOTAL"
        ],
        "Labels": [
          "GPU_UUID", "SERIAL_NUMBER", "GPU_ID", "POD", "NAMESPACE", "CONTAINER",
          "CLUSTER_NAME", "CARD_SERIES", "CARD_MODEL", "CARD_VENDOR",
          "DRIVER_VERSION", "VBIOS_VERSION", "HOSTNAME"
        ],
        "ExtraPodLabels": {
          "WORKLOAD_ID": "airm.silogen.ai/workload-id",
          "PROJECT_ID": "airm.silogen.ai/project-id"
        },
        "CustomLabels": {
          "KUBE_CLUSTER_NAME": "${CLUSTER_NAME}"
        }
      }
    }
EOF

# The gpu-operator chart installs the controllers only. The device plugin, the
# node labeller and the metrics exporter come from a DeviceConfig. Without this
# object the node never advertises amd.com/gpu and no GPU workload schedules.
# driver.enable is false, because cluster-bloom installs the host driver.
kubectl apply --filename - <<EOF
apiVersion: amd.com/v1alpha1
kind: DeviceConfig
metadata:
  name: gpu-operator
  namespace: kube-amd-gpu
spec:
  driver:
    enable: false
    blacklist: false
    version: "${DRIVER_VERSION}"
  devicePlugin:
    devicePluginImage: rocm/k8s-device-plugin:latest
    nodeLabellerImage: rocm/k8s-device-plugin:labeller-latest
    enableNodeLabeller: true
  metricsExporter:
    enable: true
    serviceType: NodePort
    port: 5000
    nodePort: 32500
    image: docker.io/rocm/device-metrics-exporter:v1.4.1
    config:
      name: gpu-config
  selector:
    feature.node.kubernetes.io/amd-gpu: "true"
EOF

require_allocatable_gpu() {
  local deadline=$((SECONDS + GPU_READY_TIMEOUT_SECONDS))
  local total
  while ((SECONDS < deadline)); do
    total="$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.status.allocatable.amd\.com/gpu}{"\n"}{end}' \
      2>/dev/null | grep -c '^[1-9]' || true)"
    if [[ "${total}" -gt 0 ]]; then
      echo "the DeviceConfig is ready: ${total} node(s) advertise amd.com/gpu"
      return 0
    fi
    sleep 15
  done
  echo "no node advertises amd.com/gpu after ${GPU_READY_TIMEOUT_SECONDS}s." >&2
  echo "check: kubectl describe deviceconfig gpu-operator --namespace kube-amd-gpu" >&2
  return 1
}

require_allocatable_gpu

kubectl apply --server-side --force-conflicts \
  --filename https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml

helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.13.0 \
  --namespace kueue-system --create-namespace \
  --wait --timeout 6m

helm upgrade --install kuberay-operator kuberay/kuberay-operator --version 1.4.2 \
  --namespace default \
  --wait --timeout 6m

helm upgrade --install keda kedacore/keda --version 2.18.1 \
  --namespace keda --create-namespace \
  --wait --timeout 6m

helm_manifest kaiwo-crds oci://ghcr.io/silogen/kaiwo-crds-chart --version v0.2.1 \
  | kubectl apply --server-side --force-conflicts --filename -
helm upgrade --install kaiwo oci://ghcr.io/silogen/kaiwo-operator-chart --version v0.2.1 \
  --namespace kaiwo-system --create-namespace \
  --wait --timeout 6m

helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.16.0 \
  --namespace kserve-system --create-namespace \
  --wait --timeout 6m
# The kserve chart creates its webhook Deployment and 11 ClusterServingRuntime
# objects in one release. Helm applies a ClusterServingRuntime before the
# webhook pod has an endpoint, so the validating webhook call fails and the
# whole release aborts. The chart gives no value to omit those objects.
#
# The failed release leaves the webhook Deployment on the cluster. Each retry
# waits for that Deployment to serve an endpoint, and then installs again. Helm
# 4 accepts an upgrade of a release whose first install failed, so the retry
# must NOT remove the release first: an uninstall deletes the webhook as well,
# and the next attempt meets the same race.
install_kserve() {
  local attempt
  for attempt in $(seq 1 "${KSERVE_ATTEMPTS}"); do
    echo "kserve: attempt ${attempt} of ${KSERVE_ATTEMPTS}"
    if helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve --version v0.16.0 \
        --namespace kserve-system \
        --set kserve.controller.deploymentMode=Standard \
        --set kserve.controller.gateway.ingressGateway.enableGatewayApi=false \
        --wait --timeout 8m; then
      return 0
    fi
    wait_for_kserve_webhook
  done
  echo "kserve did not install in ${KSERVE_ATTEMPTS} attempts" >&2
  return 1
}

wait_for_kserve_webhook() {
  local endpoint
  kubectl rollout status deployment/kserve-controller-manager \
    --namespace kserve-system --timeout=5m || true
  for _ in $(seq 1 30); do
    endpoint="$(kubectl get endpoints kserve-webhook-server-service \
      --namespace kserve-system \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "${endpoint}" ]]; then
      echo "the kserve webhook serves at ${endpoint}"
      return 0
    fi
    sleep 5
  done
  echo "the kserve webhook has no endpoint yet" >&2
}

install_kserve

ensure_ns aim-system
helm upgrade --install aim-engine "${OCI}/aim-engine-chart" \
  --version 0.2.6 \
  --namespace aim-system \
  --set manager.image.repository=amdenterpriseai/aim-engine \
  --set manager.image.tag=v0.2.6 \
  --set manager.artifactDownloaderImage=docker.io/amdenterpriseai/aim-artifact-downloader:v0.2.6 \
  --set clusterRuntimeConfig.enable=false \
  --wait --timeout 6m
