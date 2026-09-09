# Footprint of the scalable-inference profile

Measured on 2026-09-09 on one Kaytoo VM, OCI, 16 vCPU and 94 GiB memory, with
Kubernetes from `spur k8s up`. The profile is `scalable-inference` with the
`kyverno` and `kyverno-policies-storage-local-path` packages, which the
local-path StorageClass makes necessary.

This document holds minimal numbers only. There is no baseline from a full
cluster-forge install.

| Item | Value |
|---|---|
| date | 2026-09-09 |
| kubernetes | v1.36.2+k0s, one node |
| VM shape | 16 vCPU, 94 GiB memory, 96 GiB boot disk |
| profile | scalable-inference |
| install wall-clock time | 2 min 58 s |
| container images on the node | 96 images, 14 GiB in /var/lib/k0s/containerd |

The install time is for a second run, when the images were already on the node.
The 14 GiB includes the k0s system images.

## Idle

Six pods, no model running.

| namespace | pods | cpu requests | memory requests | cpu limits | memory limits |
|---|---|---|---|---|---|
| kyverno | 1 | 100m | 128Mi | 0m | 384Mi |
| cert-manager | 3 | 0m | 0Mi | 0m | 0Mi |
| kserve-system | 1 | 200m | 600Mi | 200m | 600Mi |
| aim-system | 1 | 100m | 256Mi | 0m | 4096Mi |
| **total** | **6** | **400m** | **984Mi** | **200m** | **5080Mi** |

Live usage from `kubectl top`: 10 mCPU and 217 MiB together.

## With the dummy service

The same six pods and the `aims-test` namespace with the served model.

| namespace | pods | cpu requests | memory requests |
|---|---|---|---|
| aims-test | 3 | 500m | 0Mi |

The three pods are the predictor and two finished cache jobs. The predictor
uses 1 mCPU and 1 MiB at rest, because the model is `sshleifer/tiny-gpt2`. The
cache PVC is 1 GiB, ReadWriteOnce after the Kyverno mutation.

Reproduce with:

```bash
byok/footprint/footprint.sh idle
NAMESPACES="kyverno cert-manager kserve-system aim-system aims-test" \
  byok/footprint/footprint.sh "with the dummy service"
```
