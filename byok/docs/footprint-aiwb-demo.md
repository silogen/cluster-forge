# Footprint of the aiwb-demo profile

Measured on 2026-09-10 on one Kaytoo VM, OCI, 16 vCPU and 94 GiB memory, with
k3s v1.36.4 and its local-path StorageClass. The profile is `aiwb-demo`, which
holds every package of `scalable-inference` and adds the gateway, PostgreSQL,
Keycloak and AIWB. The gateway is a `ClusterIP` Service with the node address
in `externalIPs`, so the cluster needs no load balancer.

This document holds minimal numbers only. There is no baseline from a full
cluster-forge install.

| Item | Value |
|---|---|
| date | 2026-09-10 |
| kubernetes | v1.36.4+k3s1, one node |
| VM shape | 16 vCPU, 94 GiB memory, 96 GiB boot disk |
| profile | aiwb-demo |
| domain | `<node-ip>.nip.io`, self-signed certificate |
| first install wall-clock time | 5 min 46 s |
| second install wall-clock time | 33 s |
| container images on the node | 39 images, 19 GiB in `/var/lib/rancher/k3s/agent/containerd` |

The first install pulls every image. The second install changes nothing and
only re-renders the releases. The 19 GiB holds the images of both profiles and
of k3s.

## Idle

Twelve pods, no model running.

| namespace | pods | cpu requests | memory requests | cpu limits | memory limits |
|---|---|---|---|---|---|
| kyverno | 1 | 100m | 128Mi | 0m | 384Mi |
| cert-manager | 3 | 0m | 0Mi | 0m | 0Mi |
| kserve-system | 1 | 200m | 600Mi | 200m | 600Mi |
| aim-system | 1 | 100m | 256Mi | 0m | 4096Mi |
| envoy-gateway-system | 2 | 210m | 800Mi | 0m | 1024Mi |
| opentelemetry-operator-system | 0 | 0m | 0Mi | 0m | 0Mi |
| postgres | 1 | 100m | 256Mi | 0m | 1024Mi |
| keycloak | 1 | 250m | 512Mi | 500m | 2048Mi |
| aiwb | 2 | 600m | 640Mi | 2500m | 2560Mi |
| **total** | **12** | **1560m** | **3192Mi** | **3200m** | **11736Mi** |

The `opentelemetry-operator-system` namespace holds the collector CRD only,
with no pod.

Live usage from `kubectl top`, the whole node: 784 mCPU and 4240 MiB, which
includes k3s itself. The largest pods are Keycloak with 837 MiB, the AIWB API
with 284 MiB and the AIWB UI with 109 MiB.

The only volume claim of the idle installation is `data-postgres-0`, 5 GiB,
ReadWriteOnce.

## With the dummy service

The `workbench` namespace with the served model, on top of the twelve pods.

| namespace | pods | cpu requests | memory requests |
|---|---|---|---|
| workbench | 3 | 500m | 0Mi |

The three pods are the predictor and two finished cache jobs. The predictor
uses about 1 mCPU at rest, because the model is `sshleifer/tiny-gpt2`. The
cache volume is 1 GiB, the floor of aim-engine, and ReadWriteOnce after the
Kyverno mutation. A larger model gets a claim of about two times the model
size, because the AIWB chart sets `pvcHeadroomPercent: 100`.

## What the measurement covers

`byok/tests/smoke-ui.sh` passed on this installation: the OIDC discovery
document answers, a password grant gives a token, the AIWB API lists the model
catalog, the UI answers, the dummy AIMService becomes Ready in the `workbench`
namespace, the API lists it, and a chat completion answers through
`https://workloads.<domain>/workbench/<workload-id>/v1/chat/completions`.
`NAMESPACE=workbench byok/tests/smoke.sh` passed as well.
