# BYOK: Minimal Installation

**Bring-your-own-Kubernetes — scalable-inference profile**

Installs a model-serving stack on an existing cluster using `helm upgrade --install` only. No ArgoCD, Gitea or OpenBao.

---

## What is included

| Package | Purpose |
|---|---|
| cert-manager | TLS certificate management |
| kserve-crds + kserve | Model serving runtime (KServe) |
| gateway-api-crds | Gateway API CRD definitions |
| aim-engine-crds + aim-engine | AIM inference engine and scheduling |
| aim-catalog | Model source configuration |
| kyverno + storage policy ¹ | Access-mode mutation for RWO storage |

¹ Required when the cluster's default StorageClass is ReadWriteOnce only (e.g. local-path-provisioner). Remove both when the cluster gives ReadWriteMany.

---

## What is NOT included

- ArgoCD, Gitea, OpenBao
- UI, gateway / ingress, autoscaling
- AIRM, AIWB, Keycloak, Kaiwo, Kueue

---

## Prerequisites

- Kubernetes cluster with a cluster-admin kubeconfig
- Default StorageClass with dynamic provisioning
- `helm` ≥ 3.8, `kubectl`, `yq` v4, `jq`, `git` on PATH

---

## Footprint (idle, one node)

Measured 2026-09-09, Spur k0s v1.36.2, 16 vCPU / 94 GiB VM.

| | Value |
|---|---|
| Pods at idle | 6 |
| CPU requests | 400 m |
| Memory requests | 984 MiB |
| Live CPU / memory | 10 mCPU / 217 MiB |
| Container images | 96 images, 14 GiB |
| Install time (warm) | ~3 min |

See [footprint-scalable-inference.md](footprint-scalable-inference.md) for three-node numbers.
