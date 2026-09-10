# byok: bring your own Kubernetes

byok installs a minimal cluster-forge on a Kubernetes cluster that already
exists. It uses `helm upgrade --install` only. It does not install ArgoCD,
Gitea or OpenBao.

There are two profiles:

- `scalable-inference` gives one model endpoint that aim-engine and KServe
  serve. It does not install AIRM, AIWB, Keycloak, Kaiwo, Kueue, a gateway or
  a UI.
- `aiwb-demo` extends `scalable-inference` with a gateway, one PostgreSQL Pod,
  a small Keycloak and AIWB. It is a reference demo installation, not a
  production installation. See [The aiwb-demo profile](#the-aiwb-demo-profile).

This path runs beside the ArgoCD path in `root/`. It does not replace it.

## Prerequisites

- A Kubernetes cluster and a cluster-admin kubeconfig.
- A default StorageClass with dynamic provisioning.
- `helm` 3.8 or later, `kubectl`, `yq` v4, `jq` and `git` on your PATH.

aim-engine 0.2.5 asks for ReadWriteMany cache volumes. If your default
StorageClass gives ReadWriteOnce only, as local-path-provisioner does, keep the
`kyverno` and `kyverno-policies-storage-local-path` packages in the profile.
They rewrite the access mode at admission time. Take them out when the cluster
gives ReadWriteMany.

The core does no routing. Use a port-forward to reach the model. The core adds
no autoscaling. If a profile needs autoscaling, the cluster must give it.

## Install

```bash
export KUBECONFIG=/path/to/admin.kubeconfig
byok/bootstrap.sh install --profile byok/profiles/scalable-inference.yaml
```

To install from a git ref instead of your checkout:

```bash
byok/bootstrap.sh install --profile <file> --source github:<tag-or-branch>
```

## The aiwb-demo profile

The demo shows the whole path: log in through Keycloak, deploy a model from
the catalog with the AIWB UI, and chat with the model on CPU. AIWB runs in
standalone mode, so it needs no AIRM and no Kueue.

```bash
export KUBECONFIG=/path/to/admin.kubeconfig
byok/bootstrap.sh install --profile byok/profiles/aiwb-demo.yaml \
  --var domain=demo.example.com
```

The profile declares three variables:

| Variable | Meaning |
|---|---|
| `domain` | The DNS name under which the cluster answers. Required. Use a `nip.io` name such as `203.0.113.10.nip.io` when there is no real DNS name. |
| `gatewayServiceType` | Service type of the Envoy data plane. Default `LoadBalancer`. |
| `gatewayExternalIP` | Node address that a `ClusterIP` Service also answers on. Optional. |

The install prints the URLs and the login of the demo user at the end.

### How traffic reaches the gateway

- **A cloud load balancer or MetalLB**: keep the default
  `gatewayServiceType=LoadBalancer`. Point `*.<domain>` at the address of the
  Service.
- **No load balancer**: use `--var gatewayServiceType=ClusterIP --var
  gatewayExternalIP=<node-ip>`. The Service keeps the node address in
  `externalIPs`, so the node answers on port 443.
- **Neither works**: use `--var gatewayServiceType=NodePort` and the port that
  the Service gets.

### What the demo does not do

- The API-key page answers 503. There is no cluster-auth and no OpenBao.
- Datasets, artifacts and models that need S3 answer "storage unavailable".
  There is no S3 in the profile. The `seaweedfs-operator` and `seaweedfs`
  packages are in the profile as comments.
- The metrics panels stay empty. There is no Prometheus.
- The browser shows a certificate warning, because the `selfsigned-tls`
  package makes a self-signed certificate. Take that package out and bring
  your own `cluster-tls` Secret in `envoy-gateway-system` to remove the
  warning.
- PostgreSQL is one Pod with one volume. There is no backup and no high
  availability.
- A model volume is about two times the model size, because the AIWB chart
  sets `pvcHeadroomPercent: 100`.

### The Secrets

The `aiwb-demo-secrets` package makes every Secret that AIWB, Keycloak and
PostgreSQL read. It makes each password once and reads it back with `lookup`
on the next run, so an upgrade does not rotate it. `lookup` gives nothing
under `helm template` and under ArgoCD, so the package works with
`bootstrap.sh` only.

This is the package to replace with your own secret management. The
`secrets.aiwb-demo` capability probe looks for the Secrets themselves, so when
they already exist the package can leave the profile.

## Install on a Spur k0s cluster

`spur/install.sh` does the whole install on a node of a Spur cluster that
runs Kubernetes from `spur k8s up`. Copy the script to a node and run it:

```bash
scp byok/spur/install.sh ubuntu@<node>:
ssh ubuntu@<node> ./install.sh --ref <tag-or-branch> --smoke
ssh ubuntu@<node> ./install.sh --ref <tag-or-branch> --profile aiwb-demo --smoke
```

The script installs `helm`, `kubectl`, `yq` and `jq` when they are missing,
gets the cluster-admin kubeconfig from Spur, clones cluster-forge at `--ref`
into `~/cluster-forge`, runs `bootstrap.sh install` with the profile of
`--profile`, and with `--smoke` runs the smoke tests. Run it again to upgrade.
See `install.sh --help` for the options and the environment variables.

For the `aiwb-demo` profile the script fills the domain with
`<node-ip>.nip.io` and gives the node address to the Envoy Service in
`externalIPs`, so the cluster needs no load balancer. `--domain` and
`GATEWAY_SERVICE_TYPE` override both.

Spur's k0s gives local-path-provisioner as the default StorageClass. The
default `spur k8s kubeconfig` is namespace-scoped, so it is not enough. The
script asks Spur for the admin kubeconfig, which needs
`allow_admin_kubeconfig = true` in the `[cluster]` section of `spur.conf`. On
the control-plane node the script falls back to `k0s kubeconfig admin`.

A Spur cluster with more than one node needs pod traffic between the nodes.
On OCI the default kube-router mode does not give that. See
[Future work](docs/future-work.md) for the workaround that the three-node test
used.

## Validate

```bash
byok/bootstrap.sh validate --profile byok/profiles/scalable-inference.yaml
```

Validation runs before every install. Each `requires` entry of a package must
be satisfied by a package earlier in the profile, or by a cluster probe from
`capabilities.yaml`. The script stops at the first miss and names the
capability and the packages that give it.

## Remove

```bash
byok/bootstrap.sh remove seaweedfs                    # keeps the CRDs and the PVCs
byok/bootstrap.sh remove seaweedfs --purge            # also removes them
byok/bootstrap.sh remove seaweedfs-operator --purge   # the CRDs live here
```

`remove` refuses to remove a package that another installed package needs.
An install run never removes anything. A package that you take out of the
profile stays installed until you call `remove`.

## Upgrade

Run `install` again with the same profile. The command is idempotent.

## Test

```bash
byok/tests/smoke.sh                   # the core serves a model
NAMESPACE=workbench byok/tests/smoke.sh   # the same on an aiwb-demo cluster
byok/tests/smoke-ui.sh                # login, API, deploy and chat
byok/tests/optional-package-cycle.sh  # add, re-install and purge seaweedfs
byok/tests/check-version-drift.sh     # pins agree with root/values.yaml
byok/tests/validate-negative.sh       # validation stops a bad profile
```

`smoke.sh` pulls `ghcr.io/silogen/aim-dummy`. The image is public. If your
cluster needs credentials for ghcr.io, set `GHCR_PULL_SECRET_JSON` to a docker
config JSON before you run it.

## Packages

| Package | Namespace | Provides | Requires |
|---|---|---|---|
| kyverno | kyverno | policy.kyverno | (none) |
| kyverno-policies-storage-local-path | kyverno | storage.access-mode-mutation | policy.kyverno |
| cert-manager | cert-manager | certificates.cert-manager | (none) |
| kserve-crds | kserve-system | serving.kserve.crds | (none) |
| kserve | kserve-system | serving.kserve | serving.kserve.crds, certificates.cert-manager |
| gateway-api-crds | gateway-api | gateway.api.crds | (none) |
| aim-engine-crds | aim-system | inference.aim.crds | (none) |
| aim-engine | aim-system | inference.aim | inference.aim.crds, gateway.api.crds, serving.kserve, storage.default-class |
| aim-catalog | aim-system | catalog.aim | inference.aim |
| seaweedfs-operator (optional) | seaweedfs-operator | storage.s3.operator | (none) |
| seaweedfs (optional) | seaweedfs-instance | storage.s3 | storage.s3.operator, storage.default-class |
| envoy-gateway | envoy-gateway-system | gateway.api | gateway.api.crds |
| selfsigned-tls | envoy-gateway-system | tls.cluster-cert | certificates.cert-manager |
| envoy-gateway-config | envoy-gateway-system | gateway.https | gateway.api, tls.cluster-cert |
| opentelemetry-crds | opentelemetry-operator-system | telemetry.otel.crds | (none) |
| aiwb-demo-secrets | aiwb | secrets.aiwb-demo | (none) |
| postgres | postgres | database.postgres | storage.default-class, secrets.aiwb-demo |
| keycloak | keycloak | auth.oidc | database.postgres, gateway.https, secrets.aiwb-demo |
| aiwb | aiwb | workbench.ui | auth.oidc, database.postgres, gateway.https, inference.aim, policy.kyverno, telemetry.otel.crds, secrets.aiwb-demo |

The last nine rows belong to the `aiwb-demo` profile.

Several components ship their CRDs in one chart and objects of those CRDs in
another. Helm builds the whole release manifest before it applies anything, so
one release cannot hold both. Such a component is two packages: `kserve-crds`
and `kserve`, `aim-engine-crds` and `aim-engine`, `seaweedfs-operator` and
`seaweedfs`.

### How to write a package

A package is a directory under `packages/` with four files:

- `Chart.yaml`: an umbrella chart that pins its dependencies. Use
  `file://../../../sources/<path>` for a chart that this repository holds, and
  an `oci://` repository with an exact version for a chart that it does not.
- `Chart.lock`: commit it. `helm dependency build` writes it.
- `values.yaml`: the default values of the package.
- `package.yaml`: the name, the namespace, and the `provides` and `requires`
  capability lists.

One package installs as one Helm release in one namespace. Add a new
capability name to `capabilities.yaml` together with a probe that tells if the
cluster already gives it.

### How to write a profile

A profile is a name and an ordered package list. The list order is the install
order. A `values` block merges on top of the package `values.yaml`.

`extends: <name>` takes the packages of another profile in the same directory.
The base packages come first, an entry with the same name replaces the base
entry in place, and the entries that only the child has follow. A base profile
must not extend a third profile.

`vars` declares the inputs. `--var name=value` fills one. A variable that the
profile declares as null needs a value and stops the run without one. A
variable that the profile declares as an empty string is optional.
`${name}` in the text of the profile takes the value. A `${name}` that no
profile declares stops the run.

`notes` is printed after a successful install, with the variables filled in.

```yaml
name: my-profile
extends: scalable-inference
vars:
  domain:
packages:
  - name: aim-engine
    values:
      aim-engine-chart:
        clusterRuntimeConfig:
          enable: true
  - name: selfsigned-tls
    values:
      cert-manager-config:
        domain: ${domain}
notes: |
  The cluster answers under ${domain}.
```

## Documents

- [Footprint of scalable-inference](docs/footprint-scalable-inference.md)
- [Footprint of aiwb-demo](docs/footprint-aiwb-demo.md)
- [Future work](docs/future-work.md)
