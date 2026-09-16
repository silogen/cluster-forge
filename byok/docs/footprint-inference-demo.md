# Footprint of the inference-demo profile

Measured on 2026-09-11 on one Kaytoo VM, OCI, 16 vCPU and 94 GiB memory, with
a single-node Spur k0s cluster, k0s v1.36.2, and its local-path StorageClass.
The profile is `inference-demo`, which holds every package of
`inference` and adds the gateway, PostgreSQL, Dex and AIWB. The
gateway is a `ClusterIP` Service with the node address in `externalIPs`, so
the cluster needs no load balancer.

The AIWB images and chart of this measurement come from the core branch that
adds the `oidc` block to the aiwb chart, built locally as `2.0.2-oidc.1`.
The measurement of 2026-09-10 with Keycloak, k3s and aiwb-chart 2.0.0 is in
the git history of this file.

This document holds minimal numbers only. There is no baseline from a full
cluster-forge install.

| Item | Value |
|---|---|
| date | 2026-09-11 |
| kubernetes | v1.36.2+k0s, one node |
| VM shape | 16 vCPU, 94 GiB memory, 96 GiB boot disk |
| profile | inference-demo |
| domain | `<node-ip>.nip.io`, self-signed certificate |
| install of the demo layer on top of `inference` | 1 min 17 s |
| second install wall-clock time | 29 s |
| container images on the node | 119 images, 19 GiB in `/var/lib/k0s/containerd` |

The demo layer is `aiwb-demo-secrets`, `postgres`, `dex` and `aiwb`, with
the images already on the node. The second install changes nothing and only
re-renders the releases. The 19 GiB holds the images of both profiles, of
k0s, and of a few test images.

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
| dex | 1 | 20m | 64Mi | 0m | 128Mi |
| aiwb | 2 | 600m | 1024Mi | 4000m | 6144Mi |
| **total** | **12** | **1330m** | **3128Mi** | **4200m** | **13400Mi** |

The `opentelemetry-operator-system` namespace holds the collector CRD only,
with no pod. The aiwb row follows the chart of the core branch, which asks
for more than aiwb-chart 2.0.0 did.

Dex replaces Keycloak: 20 mCPU and 64 MiB requested where Keycloak requested
250 mCPU and 512 MiB, and one database instead of two. The Dex image is
44 MiB where the Keycloak image was about 470 MiB.

Live usage from `kubectl top`, the whole node: 681 mCPU and 3539 MiB, which
includes k0s itself. The largest pods are the AIWB API with 276 MiB and the
AIWB UI with 124 MiB. Dex uses 1 mCPU and 7 MiB. With Keycloak the node used
784 mCPU and 4240 MiB, and Keycloak alone 837 MiB.

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
document of Dex answers, a password grant gives a token, the AIWB API lists
the model catalog, the UI answers and sends the login to Dex, the dummy
AIMService becomes Ready in the `workbench` namespace, the API lists it, and
a chat completion answers through
`https://workloads.<domain>/workbench/<workload-id>/v1/chat/completions`.
`NAMESPACE=workbench byok/tests/smoke.sh` passed as well.

The browser login was driven with curl on the node: the UI sends the browser
to `https://auth.<domain>/auth`, Dex shows its login form, the callback of
the UI exchanges the code on the in-cluster Dex address, the session holds
the email and an access token with `iss` and `aud` of Dex, the API answers
200 to that token, and the logout route answers with the app URL because Dex
has no end session endpoint.
