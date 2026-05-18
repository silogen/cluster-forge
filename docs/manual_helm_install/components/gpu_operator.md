# AMD GPU Operator

This guide describes the AMD GPU Operator that `install_base.sh` deploys automatically and covers optional configuration for out-of-tree drivers, custom DeviceConfig, and Prometheus metrics scraping.

## Overview

The AMD GPU Operator manages the full lifecycle of AMD GPU resources on Kubernetes nodes. It installs and coordinates four components:

| Component | Purpose |
|-----------|---------|
| **Node Feature Discovery (NFD)** | Detects AMD GPUs via PCI vendor ID and labels nodes with `feature.node.kubernetes.io/amd-gpu: "true"` |
| **Kernel Module Management (KMM)** | Manages out-of-tree AMD GPU kernel module builds and upgrades (disabled by default — inbox driver is used) |
| **Device Plugin** | Registers `amd.com/gpu` resources with the kubelet so workloads can request them |
| **Device Metrics Exporter** | Exports 95+ GPU metrics (power, temperature, memory, activity, PCIe) on port 5000 |

All four components are deployed via a single `DeviceConfig` custom resource that the operator reconciles.

## Prerequisites

1. Kubernetes 1.29 or later
2. Nodes with AMD Instinct or Radeon GPU hardware
3. `install_base.sh` has been run (the operator is installed as part of that script)
4. Inbox AMD GPU driver loaded on nodes (verify with `lsmod | grep amdgpu`)

## What install_base.sh installs

`install_base.sh` deploys the operator chart from `sources/amd-gpu-operator/v1.4.1` with these defaults:

- NFD enabled — nodes are labelled automatically based on PCI device detection
- KMM enabled — standing by to manage out-of-tree modules if requested
- Default DeviceConfig deployed (`crds.defaultCR.install=true`) — targets all nodes labelled `feature.node.kubernetes.io/amd-gpu: "true"`
- Out-of-tree driver management **disabled** — the inbox `amdgpu` kernel module is used
- Device plugin and node labeller running on all detected GPU nodes
- Metrics exporter running on all detected GPU nodes (ClusterIP, port 5000)

All components land in the `amd-gpu-operator` namespace.

## Verify GPU nodes are detected

After `install_base.sh` completes, check that the operator and its sub-components are running:

```bash
kubectl get pods -n amd-gpu-operator
```

Check that NFD has labelled GPU nodes:

```bash
kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["feature.node.kubernetes.io/amd-gpu"] == "true") | .metadata.name'
```

Check that GPU resources are advertised on each labelled node:

```bash
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, gpus: .status.capacity["amd.com/gpu"]}'
```

Or with kubectl describe:

```bash
kubectl describe node <gpu-node-name> | grep -A5 "Capacity:"
# Look for:  amd.com/gpu: N
```

Inspect the deployed DeviceConfig:

```bash
kubectl get deviceconfig -n amd-gpu-operator
kubectl describe deviceconfig default-deviceconfig -n amd-gpu-operator
```

## Optional: Enable out-of-tree driver management

By default the inbox `amdgpu` driver loaded by the OS is used. Enable out-of-tree driver management when you need a specific ROCm driver version that differs from what the OS ships.

> **Requirements:** A container registry that operator nodes can push to and pull from. KMM builds the driver image inside the cluster and stores it in this registry.

Re-apply the operator with driver management enabled:

```bash
helm template amd-gpu-operator /tmp/cluster-forge/sources/amd-gpu-operator/v1.4.1 \
  --namespace amd-gpu-operator \
  --set crds.defaultCR.install=true \
  --set deviceConfig.spec.driver.enable=true \
  --set deviceConfig.spec.driver.version="30.20.1" \
  --set deviceConfig.spec.driver.image="my-registry.example.com/amd-gpu-driver" \
  | kubectl apply --server-side -f -
```

Replace `my-registry.example.com/amd-gpu-driver` with your registry path. If the registry requires credentials, create an image pull secret and set `deviceConfig.spec.driver.imageRegistrySecret.name=<secret-name>`.

When driver management is enabled, KMM builds the kernel module on each node (or fetches a pre-built image), and the operator handles rolling upgrades across nodes with configurable parallelism (`maxParallelUpgrades: 3` by default).

## Optional: Customize the DeviceConfig

The default DeviceConfig covers most use cases. To customise it, delete the default and apply your own:

```bash
kubectl delete deviceconfig default-deviceconfig -n amd-gpu-operator
```

A fully annotated example is at `sources/amd-gpu-operator-config/deviceconfig_example.yaml`. A minimal custom DeviceConfig looks like:

```yaml
apiVersion: amd.com/v1alpha1
kind: DeviceConfig
metadata:
  name: my-deviceconfig
  namespace: amd-gpu-operator
spec:
  selector:
    feature.node.kubernetes.io/amd-gpu: "true"
  driver:
    enable: false
  devicePlugin:
    devicePluginImage: rocm/k8s-device-plugin:latest
    enableNodeLabeller: true
  metricsExporter:
    enable: true
    serviceType: ClusterIP
    port: 5000
```

Apply it:

```bash
kubectl apply -f my-deviceconfig.yaml
```

The operator reconciles new DeviceConfig resources within seconds.

## Optional: Configure custom GPU metrics labels

When integrating with AIRM (AI Resource Manager), the Device Metrics Exporter
needs custom labels so that GPU metrics can be associated with clusters,
projects, and workloads. This is done via a ConfigMap named `gpu-config` in
the `kube-amd-gpu` namespace.

A reference configuration is available at
[`sources/amd-gpu-operator-config/ConfigMap_amd-gpu-metrics-exporter-config.yaml`](../../../sources/amd-gpu-operator-config/ConfigMap_amd-gpu-metrics-exporter-config.yaml).

Key fields in the ConfigMap:

| Field | Purpose |
|-------|---------|
| `ExtraPodLabels.WORKLOAD_ID` | Maps `airm.silogen.ai/workload-id` pod label into GPU metrics for per-workload attribution |
| `ExtraPodLabels.PROJECT_ID` | Maps `airm.silogen.ai/project-id` pod label for project-level rollup |
| `CustomLabels.KUBE_CLUSTER_NAME` | Must match the cluster name registered in AIRM. Primary identifier for correlating GPU metrics with the correct cluster |

See the [core repo INSTALL.md](https://github.com/amd-enterprise-ai/amd-eai-suite/blob/main/helm/INSTALL.md#amd-device-metrics-exporter-configuration)
for the full ConfigMap template and detailed setup instructions.

## Optional: Enable Prometheus metrics scraping

The metrics exporter runs on every GPU node and listens on port 5000 by default. To configure Prometheus to scrape it automatically via a ServiceMonitor (requires Prometheus Operator CRDs to be installed):

```bash
helm template amd-gpu-operator /tmp/cluster-forge/sources/amd-gpu-operator/v1.4.1 \
  --namespace amd-gpu-operator \
  --set crds.defaultCR.install=true \
  --set deviceConfig.spec.metricsExporter.prometheus.serviceMonitor.enable=true \
  --set deviceConfig.spec.metricsExporter.prometheus.serviceMonitor.interval=30s \
  | kubectl apply --server-side -f -
```

Without Prometheus Operator, you can scrape the exporter directly:

```bash
# Port-forward the exporter on any GPU node's pod
kubectl port-forward -n amd-gpu-operator <metrics-exporter-pod> 5000:5000

# Query metrics
curl http://localhost:5000/metrics | grep gpu_
```

## Troubleshooting

**Nodes not labelled by NFD**

```bash
kubectl get pods -n amd-gpu-operator -l app=nfd-worker
kubectl logs -n amd-gpu-operator -l app=nfd-worker --tail=50
```

NFD runs as a DaemonSet — verify a pod is scheduled on each GPU node. If the node has a `NoSchedule` taint, add a toleration to the NFD worker via `node-feature-discovery.worker.tolerations` in the chart values.

**Device plugin not registering GPUs**

```bash
kubectl get pods -n amd-gpu-operator -l app=amd-gpu-device-plugin
kubectl logs -n amd-gpu-operator -l app=amd-gpu-device-plugin --tail=50
```

The device plugin pod must run on each GPU node. If the node is not labelled (see NFD above), the DeviceConfig selector will not match and the device plugin DaemonSet will not schedule there.

**KMM module build failures** (out-of-tree driver only)

```bash
kubectl get modules -n amd-gpu-operator
kubectl describe module amd-gpu -n amd-gpu-operator
kubectl get builds -A | grep amd
```

Build failures are usually caused by a missing or inaccessible base kernel image, or registry push credentials. Check the build pod logs for the specific error.

**Driver image pull errors**

```bash
kubectl get events -n amd-gpu-operator --field-selector type=Warning | grep Pull
```

Ensure the image registry is reachable from all GPU nodes and that any required image pull secret is referenced in `deviceConfig.spec.driver.imageRegistrySecret`.
