# Footprint of the default profile

Measured on 2026-09-15 on the node `useocpm2m-silogen-014`, one bare-metal
machine with 112 vCPU, 2015 GiB memory and 8 AMD Instinct MI300X GPUs, with
Kubernetes from `spur k8s up`. The profile is `inference-gpu` (now `default`),
which is `inference` (now `default-cpu`) plus the AMD GPU operator. The Go
build of `spur-silo` (now `spur-aims`) installed it and selected the
profile from the node GRES, which the plugin no longer does.

This document holds idle numbers only. No model was served during the
measurement; the smoke test object was removed first.

| Item | Value |
|---|---|
| date | 2026-09-15 |
| kubernetes | v1.36.2+k0s.0, one node |
| node shape | 112 vCPU, 2015 GiB memory, 8x MI300X (gfx942) |
| profile | inference-gpu (now default), 11 packages |
| install wall-clock time | 3 min 24 s, of which the smoke test is 31 s |
| uninstall wall-clock time | 2 min 51 s |
| images of the profile | 10.86 GiB over 17 digests |
| `amd.com/gpu` allocatable | 8 |

The install time is for a run that pulled no image again. `aim-base:0.12` is
10 GiB of the 10.86 GiB, and it is the image that a model server runs.

## Idle

Sixteen running pods, no model running.

| namespace | pods | cpu requests | memory requests | cpu limits | memory limits |
|---|---|---|---|---|---|
| kyverno | 1 | 100m | 128Mi | 0m | 384Mi |
| cert-manager | 3 | 0m | 0Mi | 0m | 0Mi |
| kserve-system | 1 | 200m | 600Mi | 200m | 600Mi |
| aim-system | 2 | 150m | 384Mi | 0m | 4608Mi |
| kube-amd-gpu | 9 | 735m | 1192Mi | 4000m | 11238Mi |
| **total** | **16** | **1185m** | **2304Mi** | **4200m** | **16830Mi** |

Live usage at idle is about 44m CPU and 424Mi memory over all of them, so the
requests are the number that matters for capacity planning.

The GPU operator is the whole difference to the CPU profile: 9 of the 16 pods,
735m of the 1185m CPU requests and 1192Mi of the 2304Mi memory requests. It
holds the KMM controller and webhook, node feature discovery (master, worker
and gc), the device plugin, the node labeller and the metrics exporter.

There are no PersistentVolumeClaims. The profile keeps no state of its own; a
model cache PVC appears only when an AIMService asks for one.

## Images

The 17 digests that the running pods of the profile reference, 10.86 GiB in
all. `aim-base` is the image a model server runs, and it is 92 % of the total.

| Size | Image |
|---|---|
| 10240.0 MiB | `amdenterpriseai/aim-base:0.12` |
| 333.9 MiB | `rocm/device-metrics-exporter:v1.4.1` |
| 121.7 MiB | `rocm/gpu-operator:v1.4.1` |
| 65.3 MiB | `registry.k8s.io/nfd/node-feature-discovery:v0.16.1` |
| 48.8 MiB | `amdenterpriseai/aim-engine:v0.2.5` |
| 42.6 MiB | `kserve/kserve-controller:v0.16.0` |
| 40.3 MiB | `reg.kyverno.io/kyverno/kyverno:v1.15.1` |
| 36.1 MiB | `reg.kyverno.io/kyverno/kyvernopre:v1.15.1` |
| 32.1 MiB | `rocm/kernel-module-management-operator:v1.4.1` |
| 30.7 MiB | `rocm/kernel-module-management-webhook-server:v1.4.1` |
| 30.1 MiB | `rocm/k8s-device-plugin:labeller-latest` |
| 29.7 MiB | `quay.io/brancz/kube-rbac-proxy:v0.18.0` |
| 20.9 MiB | `quay.io/jetstack/cert-manager-controller:v1.18.2` |
| 18.0 MiB | `quay.io/jetstack/cert-manager-webhook:v1.18.2` |
| 16.2 MiB | `rocm/k8s-device-plugin:latest` |
| 15.3 MiB | `quay.io/jetstack/cert-manager-cainjector:v1.18.2` |
| 2.1 MiB | `docker.io/library/busybox:1.36` |

The GPU operator brings six of these, `rocm/*` and the node feature discovery
image, about 630 MiB together.

## What the numbers do not say

- The cert-manager pods declare no requests and no limits, so the scheduler
  does not see them. Their live usage is about 4m CPU and 103Mi memory.
- `aim-catalog` leaves the pods of its discovery Jobs behind in `Succeeded`.
  They hold no resources, but a `kubectl get pods -n aim-system` shows
  hundreds of them. See `spur-aims-findings.md`.
- The containerd directory of the node held 268 GiB over 400 images at the
  time of the measurement. That is the result of earlier test rounds on the
  same node, not the footprint of this profile.
