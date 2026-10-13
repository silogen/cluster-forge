# Spur: Minimal Installation

**AIMs in a Spur k0s Kubernetes cluster, the default-cpu profile**

Installs a model-serving stack on an existing cluster with the `spur aims` plugin, one Helm release per package. No ArgoCD, Gitea or OpenBao. The `default` profile adds the AMD GPU operator for AMD Instinct GPUs.

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
- AIRM, AIWB, Dex, Kaiwo, Kueue

---

## Prerequisites

- Kubernetes cluster with a cluster-admin kubeconfig
- Default StorageClass with dynamic provisioning
- Nothing on the node: the `spur-aims` binary holds the charts and Helm

---

## Footprint (idle, one node)

Measured 2026-09-09, Spur k0s v1.36.2, 16 vCPU / 94 GiB VM.

| | Value |
|---|---|
| Pods at idle | 6 |
| CPU requests | 400 m |
| Memory requests | 984 MiB |
| Live CPU / memory | 10 mCPU / 217 MiB |
| Container images on the node, k0s included | 96 images, 14 GiB |
| Install time (warm) | 2 min 58 s |

See [footprint-default-cpu.md](footprint-default-cpu.md) for three-node numbers.
