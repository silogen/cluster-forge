# byok: bring your own Kubernetes

byok installs a minimal cluster-forge on a Kubernetes cluster that already
exists. The `spur inference` plugin does the install: one Helm release per
package, with the Helm library, from the charts inside the binary. It does not
install ArgoCD, Gitea or OpenBao.

There are four profiles:

- `default` gives one model endpoint that aim-engine and KServe serve on AMD
  Instinct GPUs. It holds the AMD GPU operator, turns the accelerator detector
  on and takes the Instinct family of the catalog. It does not install AIRM,
  AIWB, Dex, Kaiwo, Kueue, a gateway or a UI.
- `default-cpu` gives the same on a cluster with no GPU: no GPU operator, the
  CPU detector on, and the EPYC family of the catalog.
- `demo` extends `default` with a gateway, one PostgreSQL Pod, Dex as the OIDC
  issuer and AIWB. It is a reference demo installation, not a production
  installation. See [The demo profile](#the-demo-profile).
- `demo-cpu` is the same demo on top of `default-cpu`.

A blank profile name is `default`. `--no-gpu` adds `-cpu` to the name. The
profile `test-s3` exists for one test only, see [Test](#test).

This path runs beside the ArgoCD path in `root/`. It does not replace it.

## Prerequisites

- A Kubernetes cluster and a cluster-admin kubeconfig, or a Spur cluster that
  gives one.
- A default StorageClass with dynamic provisioning.
- Nothing on the node. The build of the binary needs `go` and, once, `helm`
  with the network. The test scripts need `kubectl`, `helm`, `yq` v4 and `jq`.

### A k3s test cluster

Skip this section when you have a cluster. A stock k3s cluster serves the byok
packages, but Traefik takes port 443 and the ServiceLB controller answers every
`LoadBalancer` Service. Both collide with the Envoy gateway of the `demo`
profiles, so leave them out:

```bash
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=v1.36.4+k3s1 \
  INSTALL_K3S_EXEC="--disable traefik --disable servicelb --write-kubeconfig-mode 644" sh -
```

The version pin is needed, because the install script reads the channel from
`update.k3s.io`, which answers with a certificate that no client trusts. The
kubeconfig is `/etc/rancher/k3s/k3s.yaml`, and the default StorageClass is
local-path-provisioner, which gives ReadWriteOnce only.

### Storage and routing

aim-engine 0.2.5 asks for ReadWriteMany cache volumes. If your default
StorageClass gives ReadWriteOnce only, as local-path-provisioner does, keep the
`kyverno` and `kyverno-policies-storage-local-path` packages in the profile.
They rewrite the access mode at admission time. Take them out when the cluster
gives ReadWriteMany.

The core does no routing. Use a port-forward to reach the model. The core adds
no autoscaling. If a profile needs autoscaling, the cluster must give it.

## Install

Build the binary once, see [spur-inference/README.md](spur-inference/README.md):

```bash
make -C byok/spur-inference assets build
```

Then, on any cluster:

```bash
export KUBECONFIG=/path/to/admin.kubeconfig
byok/spur-inference/spur-inference install            # default, on AMD Instinct GPUs
byok/spur-inference/spur-inference install --no-gpu   # default-cpu
```

On a Spur cluster, `spur inference install` does the same and finds the
kubeconfig itself. See [Install on a Spur k0s cluster](#install-on-a-spur-k0s-cluster).

## The demo profile

The demo shows the whole path: log in through Dex, deploy a model from the
catalog with the AIWB UI, and chat with the model. AIWB runs in standalone
mode, so it needs no AIRM and no Kueue.

```bash
export KUBECONFIG=/path/to/admin.kubeconfig
byok/spur-inference/spur-inference install demo --var domain=demo.example.com
```

On a cluster without a load balancer, give the node address to the gateway and
use a `nip.io` name. On a cluster with no GPU, add `--no-gpu`:

```bash
byok/spur-inference/spur-inference install demo --no-gpu \
  --var domain=10.0.255.181.nip.io \
  --var gatewayServiceType=ClusterIP \
  --var gatewayExternalIP=10.0.255.181
```

The profile declares three variables:

| Variable | Meaning |
|---|---|
| `domain` | The DNS name under which the cluster answers. Required. Use a `nip.io` name such as `203.0.113.10.nip.io` when there is no real DNS name. |
| `gatewayServiceType` | Service type of the Envoy data plane. Default `LoadBalancer`. |
| `gatewayExternalIP` | Node address that a `ClusterIP` Service also answers on. Optional. |

The install prints the URLs and the login of the demo user at the end.

### The login

Dex is the OIDC issuer of the demo: one Pod, one static user
`devuser@<domain>`, one client `aiwb`, and its state in memory, so a restart
of the Pod ends every session. The `aiwb-demo-secrets` package makes the
password and the client secret. AIWB logs in through any OIDC issuer: the
`oidc` block of the aiwb chart holds the issuer, the internal URL, the client
and the JWKS URL. Replace the `dex` package with your own issuer and set that
block in the profile.

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

- The API-key page is hidden and its endpoints answer 503. There is no
  cluster-auth and no OpenBao.
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

The `aiwb-demo-secrets` package makes every Secret that AIWB, Dex and
PostgreSQL read. It makes each password once and reads it back with `lookup`
on the next run, so an upgrade does not rotate it. `lookup` gives nothing
under `helm template` and under ArgoCD, so the package works with the plugin
only.

This is the package to replace with your own secret management. The
`secrets.demo` capability probe looks for the Secrets themselves, so when they
already exist the package can leave the profile.

## Install on a Spur k0s cluster

[Set up one node for byok with Spur](docs/spur-node-setup.md) holds every step
from a node that runs nothing to a profile that serves a model. The rest of
this section is the plugin itself.

`spur inference` does the whole install on a Spur cluster that runs Kubernetes
from `spur k8s up`. It is a Spur CLI plugin: put it on `PATH` under the name
`spur-inference` and `spur inference ...` runs it. It also works when it is
called directly.

The binary holds every chart, profile and capability probe of its release, so
the node needs no tool and no access to GitHub. Build it with `make -C
byok/spur-inference` (see `spur-inference/README.md`) and copy it to the node:

```bash
scp byok/spur-inference/spur-inference ubuntu@<node>:
ssh ubuntu@<node> 'sudo install -m 755 spur-inference /usr/local/bin/spur-inference'
ssh ubuntu@<node> 'spur inference install'
ssh ubuntu@<node> 'spur inference install demo --var domain=<node-ip>.nip.io \
  --var gatewayServiceType=ClusterIP --var gatewayExternalIP=<node-ip>'
```

| Command | What it does |
|---|---|
| `spur inference list` | The profiles of this plugin release. |
| `spur inference install [<profile>]` | Install the profile, `default` when the name is blank. `--var name=value` per profile variable. `--no-gpu` adds `-cpu` to the name. |
| `spur inference validate [<profile>]` | The capability check of `install`, with nothing installed. Takes the same name rules and variables. |
| `spur inference status` | The install record and the live capability probes. |
| `spur inference uninstall [<profile>]` | Show what goes, ask, then remove the packages of the profile. A blank name is every recorded profile. `--yes` skips the question, `--keep-data` keeps the PVCs and the CRDs. |

There is no `upgrade`. An upgrade is an `install` from a newer build.

There is no auto-fill for a profile variable: `install demo` without
`--var domain=` stops with an error. On a k0s cluster that has no load
balancer, give all three variables as in the example above.

The plugin never selects a profile on its own. `install` and `validate` ask
Spur for the GPU of every node and print a warning when the profile and the
GPUs do not go together: a `-cpu` profile on a cluster with AMD Instinct
GPUs, a GPU profile on a cluster with no GPU, or a GPU that is not Instinct.
The GPU profile supports Instinct only; on a node with another AMD GPU the
`-cpu` profile is the supported choice. The warning never changes the name
and never stops the command.

Every install writes the profile, the ref, the time and the variables into the
ConfigMap `install-record` in the namespace `inference-system`. `uninstall`
reads it: a package that another recorded profile also holds stays on the
cluster, so `uninstall demo` on a cluster that also has `default` keeps the
base packages.

Spur's k0s gives local-path-provisioner as the default StorageClass. The
default `spur k8s kubeconfig` is namespace-scoped, so it is not enough. The
plugin asks Spur for the admin kubeconfig, which needs
`allow_admin_kubeconfig = true` in the `[cluster]` section of `spur.conf`. On
the control-plane node it falls back to `sudo k0s kubeconfig admin`.
`--kubeconfig <path>` and `KUBECONFIG` win over both. Without them the order
is: Spur, Spur under `sudo -n`, then `sudo -n k0s kubeconfig admin`.

A Spur cluster with more than one node needs pod traffic between the nodes.
On OCI the default kube-router mode does not give that. See
[Future work](docs/future-work.md) for the workaround that the three-node test
used.

## Validate

```bash
spur inference validate                     # default
spur inference validate --no-gpu            # default-cpu
spur inference validate demo --var domain=demo.example.com
```

`validate` needs the same `--var` values as `install`, so a missing variable
shows before anything installs.

Validation runs before every install. Each `requires` entry of a package must
be satisfied by a package earlier in the profile, or by a cluster probe of
`capabilities.yaml`. The plugin stops at the first miss and names the
capability and the packages that give it.

## Remove

```bash
spur inference uninstall demo               # shows the plan, asks, keeps the CRDs of default
spur inference uninstall demo --keep-data   # also keeps the PVCs and the CRDs of demo
spur inference uninstall --yes              # every recorded profile, no question
```

`uninstall` removes the packages of the profile in reverse install order. It
reads the install record: a package that another recorded profile also holds
stays on the cluster, and so does every CRD that such a package ships. Before
the first removal it prints, for every profile of the run, what goes, what
stays, what is not installed, and the namespaces that the purge deletes with
their PVCs. Then it asks `Remove? [y/N]`. `--yes` skips the question. When
stdin is not a terminal and `--yes` is absent, the command refuses.

A blank name removes every recorded profile, a profile that extends another
recorded profile before its base.

`uninstall` refuses to remove a package that another installed package needs.
An install run never removes anything. A package that you take out of the
profile stays installed until you call `uninstall`. The plugin removes
profiles, not single packages: to add and remove an optional package, put it
in a profile that extends the installed one, as `test-s3` does, and uninstall
that profile.

## Upgrade

Run `install` again with the same profile. The command is idempotent.

## Test

```bash
make -C byok/spur-inference assets test     # no cluster: the profile rules,
                                            # the drift of the -cpu copies,
                                            # the removal plan and the probes
byok/tests/smoke.sh                   # the core serves a model
NAMESPACE=workbench byok/tests/smoke.sh   # the same on a demo cluster
AIM_OBJECT=byok/tests/aimservice-gpu.yaml \
  byok/tests/smoke.sh                 # a real model on a GPU cluster
byok/tests/smoke-ui.sh                # login, API, deploy and chat
byok/tests/optional-package-cycle.sh  # add, re-install and purge seaweedfs
                                      # through the test-s3 profile
byok/tests/check-version-drift.sh     # pins agree with root/values.yaml
```

`smoke-ui.sh` and `NAMESPACE=workbench smoke.sh` need a `demo` cluster.
`AIM_OBJECT` takes any AIMService object. `aimservice-gpu.yaml` holds a model
image of `amdenterpriseai` and needs a `default` cluster. The image is public,
so `PULL_SECRET_JSON` is optional: it lifts the Docker Hub rate limit of an
anonymous pull. `check-version-drift.sh` and the Go tests need no cluster.
`smoke.sh` without the variable and `optional-package-cycle.sh` need a
`default-cpu` cluster: the cycle test installs that profile and `test-s3` on
top of it, and its aim-engine package takes the `AIMClusterRuntimeConfig`
that the aiwb release owns on a `demo` cluster.

## Measure the footprint

```bash
byok/footprint/footprint.sh idle > /tmp/footprint.md
NAMESPACES="kyverno cert-manager kserve-system aim-system envoy-gateway-system \
  opentelemetry-operator-system postgres dex aiwb" \
  byok/footprint/footprint.sh idle          # the demo namespaces
NAMESPACES="kyverno cert-manager kserve-system aim-system kube-amd-gpu" \
  byok/footprint/footprint.sh idle          # the default namespaces
```

The script prints markdown: pods, requests and limits per namespace, live usage
from `kubectl top`, the volume claims, and the image size on the node. Run it on
a node to get the image size.

`smoke.sh` pulls `ghcr.io/silogen/aim-dummy`. The image is public. If your
cluster needs credentials for ghcr.io, set `PULL_SECRET_JSON` to a docker
config JSON before you run it.

## Packages

| Package | Namespace | Provides | Requires |
|---|---|---|---|
| kyverno | kyverno | policy.kyverno | (none) |
| kyverno-policies-storage-local-path | kyverno | storage.access-mode-mutation | policy.kyverno |
| cert-manager | cert-manager | certificates.cert-manager | (none) |
| amd-gpu-operator | kube-amd-gpu | gpu.amd.operator | certificates.cert-manager |
| amd-gpu-operator-config | kube-amd-gpu | gpu.amd | gpu.amd.operator |
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
| aiwb-demo-secrets | aiwb | secrets.demo | (none) |
| postgres | postgres | database.postgres | storage.default-class, secrets.demo |
| dex | dex | auth.oidc | gateway.https, secrets.demo |
| aiwb | aiwb | workbench.ui | auth.oidc, database.postgres, gateway.https, inference.aim, policy.kyverno, telemetry.otel.crds, secrets.demo |

The last nine rows belong to the `demo` profiles. The two `amd-gpu-operator`
rows belong to the GPU profiles only.

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
cluster already gives it, and the same probe as Go code in
`spur-inference/probes.go`.

### How to write a profile

A profile is a name and an ordered package list. The list order is the install
order. A `values` block merges on top of the package `values.yaml`.

`extends: <name>` takes the packages of another profile in the same directory.
The base packages come first, an entry with the same name replaces the base
entry in place, and the entries that only the child has follow. A base profile
must not extend a third profile. An entry that replaces a base entry replaces
it as a whole, so it must restate every value of the base entry that it wants
to keep.

A `-cpu` profile is a full copy of its GPU twin, not an extends child: extends
cannot take a package out of the base list, and the GPU operator must install
before aim-engine. The test `profiles_test.go` holds the copies to exactly
three differences: the two GPU packages, the catalog family, and the CPU
detector.

`vars` declares the inputs. `--var name=value` fills one. A variable that the
profile declares as null needs a value and stops the run without one. A
variable that the profile declares as an empty string is optional.
`${name}` in the text of the profile takes the value. A `${name}` that no
profile declares stops the run.

`notes` is printed after a successful install, with the variables filled in.

```yaml
name: my-profile
extends: default
vars:
  domain:
packages:
  - name: aim-engine
    values:
      aim-engine-chart:
        acceleratorDetector:
          enable: true
          cpu:
            enable: false
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

- [Footprint of default-cpu](docs/footprint-default-cpu.md)
- [Footprint of default](docs/footprint-default.md)
- [Footprint of demo](docs/footprint-demo.md)
- [The demo slide](docs/slide-demo.md)
- [The minimal install slide](docs/slide-minimal-install.md)
- [Test plan: byok on a GPU node](docs/test-plan-gpu.md)
- [Test plan: spur-inference on Kaytoo VMs](docs/test-plan-kaytoo.md)
- [spur-inference test findings](docs/spur-inference-findings.md)
- [Set up one node for byok with Spur](docs/spur-node-setup.md)
- [Spur CLI plugins](docs/spur-cli-plugins.md)
- [Future work](docs/future-work.md)
