# byok: bring your own Kubernetes

byok installs a minimal cluster-forge on a Kubernetes cluster that already
exists. It uses `helm upgrade --install` only. It does not install ArgoCD,
Gitea or OpenBao.

The reference profile `scalable-inference` gives one model endpoint that
aim-engine and KServe serve. It does not install AIRM, AIWB, Keycloak, Kaiwo,
Kueue, a gateway or a UI.

This path runs beside the ArgoCD path in `root/`. It does not replace it.

## Prerequisites

- A Kubernetes cluster and a cluster-admin kubeconfig.
- A default StorageClass with dynamic provisioning.
- `helm` 3.8 or later, `kubectl`, `yq` v4, `jq` and `git` on your PATH.

The core does no routing. Use a port-forward to reach the model. The core adds
no autoscaling. If a profile needs autoscaling, the cluster must give it.

### Spur k0s

Spur's k0s gives local-path-provisioner as the default StorageClass. The
default `spur k8s kubeconfig` is namespace-scoped, so it is not enough. Get the
admin kubeconfig with `k0s kubeconfig admin` on the node, or set
`allow_admin_kubeconfig = true`.

## Install

```bash
export KUBECONFIG=/path/to/admin.kubeconfig
byok/bootstrap.sh install --profile byok/profiles/scalable-inference.yaml
```

To install from a git ref instead of your checkout:

```bash
byok/bootstrap.sh install --profile <file> --source github:<tag-or-branch>
```

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
byok/bootstrap.sh remove seaweedfs           # keeps the CRDs and the PVCs
byok/bootstrap.sh remove seaweedfs --purge   # also removes them
```

`remove` refuses to remove a package that another installed package needs.
An install run never removes anything. A package that you take out of the
profile stays installed until you call `remove`.

## Upgrade

Run `install` again with the same profile. The command is idempotent.

## Test

```bash
byok/tests/smoke.sh                   # the core serves a model
byok/tests/optional-package-cycle.sh  # add, re-install and purge seaweedfs
byok/tests/check-version-drift.sh     # pins agree with root/values.yaml
byok/tests/validate-negative.sh       # validation stops a bad profile
```

`smoke.sh` uses a private image. Set `GHCR_PULL_SECRET_JSON` to a docker
config JSON before you run it.

## Packages

| Package | Namespace | Provides | Requires |
|---|---|---|---|
| cert-manager | cert-manager | certificates.cert-manager | (none) |
| kserve | kserve-system | serving.kserve | certificates.cert-manager |
| aim-engine | aim-system | inference.aim | serving.kserve, storage.default-class |
| aim-catalog | aim-system | catalog.aim | inference.aim |
| seaweedfs (optional) | seaweedfs-instance | storage.s3 | storage.default-class |

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

```yaml
name: my-profile
packages:
  - name: cert-manager
  - name: kserve
  - name: aim-engine
    values:
      aim-engine-chart:
        clusterRuntimeConfig:
          enable: true
```

## Documents

- [Footprint of scalable-inference](docs/footprint-scalable-inference.md)
- [Future work](docs/future-work.md)
