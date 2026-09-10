# BYOK: AIWB Demo Installation

**Bring-your-own-Kubernetes — aiwb-demo profile**

A reference demo of the AI Workbench on an existing cluster, with `helm upgrade --install` only. Log in through Keycloak, deploy a model from the catalog in the UI, chat with the model on CPU. Not a production installation.

---

## What is included

| Package | Purpose |
|---|---|
| everything in `scalable-inference` ¹ | Model serving with aim-engine and KServe |
| envoy-gateway + envoy-gateway-config | Ingress: GatewayClass and the `https` Gateway |
| selfsigned-tls | Self-signed `*.<domain>` certificate through cert-manager |
| opentelemetry-crds | The `OpenTelemetryCollector` CRD, no operator |
| aiwb-demo-secrets | Every Secret, made by the chart itself |
| postgres | One PostgreSQL Pod with two databases |
| keycloak | Keycloak with the `airm` realm and a demo user |
| aiwb | AI Workbench API and UI in standalone mode |

¹ cert-manager, KServe, aim-engine, the AIM catalog and the Kyverno storage policy.

---

## What is NOT included

- ArgoCD, Gitea, OpenBao, external-secrets, CloudNativePG
- AIRM, Kueue, Kaiwo, cluster-auth, S3, Prometheus
- A load balancer: `ClusterIP` with `externalIPs` is enough

---

## Install

```bash
byok/bootstrap.sh install --profile byok/profiles/aiwb-demo.yaml \
  --var domain=demo.example.com
```

| Variable | Meaning |
|---|---|
| `domain` | The DNS name of the cluster. A `nip.io` name works. |
| `gatewayServiceType` | `LoadBalancer` by default, `ClusterIP` or `NodePort` otherwise. |
| `gatewayExternalIP` | Node address for the `ClusterIP` Service. |

The install prints the URLs and the login of the demo user at the end.

---

## Our demo and a customer demo

The two differ in configuration only: the domain name and the way that traffic
reaches the gateway. A customer replaces two packages with their own:
`aiwb-demo-secrets` with their secret management, and `selfsigned-tls` with
their own `cluster-tls` Secret.

---

## Known limits

- The API-key page answers 503. There is no cluster-auth.
- Datasets, artifacts and S3-backed models answer "storage unavailable".
- The metrics panels stay empty. There is no Prometheus.
- The browser warns about the self-signed certificate.
- One PostgreSQL Pod, no backup and no high availability.

---

## Footprint (idle, one node)

Measured 2026-09-10, k3s v1.36.4, 16 vCPU / 94 GiB VM.

| | Value |
|---|---|
| Pods at idle | 12 |
| CPU requests | 1560 m |
| Memory requests | 3192 MiB |
| Live CPU / memory of the node | 784 mCPU / 4240 MiB |
| Container images | 39 images, 19 GiB |
| Install time (cold / warm) | 5 min 46 s / 33 s |

See [footprint-aiwb-demo.md](footprint-aiwb-demo.md) for the numbers per namespace.
