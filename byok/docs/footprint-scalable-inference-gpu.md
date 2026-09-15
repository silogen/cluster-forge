# Footprint of the scalable-inference-gpu profile

Measured on 2026-09-15 on the node `useocpm2m-silogen-014`, one bare-metal
machine with 112 vCPU, 2015 GiB memory and 8 AMD Instinct MI300X GPUs, with
Kubernetes from `spur k8s up`. The profile is `scalable-inference-gpu`, which
is `scalable-inference` plus the AMD GPU operator. The Go build of `spur-silo`
installed it and selected the profile from the node GRES.

This document holds idle numbers only. No model was served during the
measurement; the smoke test object was removed first.

| Item | Value |
|---|---|
| date | 2026-09-15 |
| kubernetes | v1.36.2+k0s.0, one node |
| node shape | 112 vCPU, 2015 GiB memory, 8x MI300X (gfx942) |
| profile | scalable-inference-gpu, 11 packages |
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

## What the numbers do not say

- The cert-manager pods declare no requests and no limits, so the scheduler
  does not see them. Their live usage is about 4m CPU and 103Mi memory.
- `aim-catalog` leaves the pods of its discovery Jobs behind in `Succeeded`.
  They hold no resources, but a `kubectl get pods -n aim-system` shows
  hundreds of them. See `spur-silo-findings.md`.
- The containerd directory of the node held 268 GiB over 400 images at the
  time of the measurement. That is the result of earlier test rounds on the
  same node, not the footprint of this profile.
