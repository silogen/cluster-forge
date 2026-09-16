# spur-silo

`spur-silo` installs an AMD Enterprise AI profile on the Kubernetes cluster that
Spur manages. Spur finds it on PATH and runs it as `spur silo ...`.

The binary holds every Helm chart of the release, the profiles, the package
metadata and the capability probes. At run time it needs no helm, kubectl, yq,
jq or git, and no access to GitHub. There is one network need left: the cluster
pulls the container images.

## Build

```sh
make assets    # needs helm and the network once, it resolves chart dependencies
make build     # needs neither
```

`make assets` copies `byok/capabilities.yaml`, `byok/profiles`, `byok/packages`
and the smoke-test object into `assets/`. That directory is a copy, so it is not
in git. `make all` does both steps.

The version string comes from `REF`, which defaults to the current branch:

```sh
make build REF=v1.2.3
```

## Use

```sh
spur silo list
spur silo install inference
spur silo install inference-demo --var domain=example.com \
  --var gatewayServiceType=LoadBalancer --var gatewayExternalIP=10.0.0.10
spur silo status
spur silo uninstall inference-demo
```

`spur silo install` selects `inference-gpu` on a cluster that has AMD
Instinct GPUs, unless `--no-gpu` is given. A Radeon GPU is never auto-selected.

The binary writes an install record into the ConfigMap `install-record` of the
namespace `silo-system`, one entry per profile. `uninstall` reads it and keeps
every package that another recorded profile holds.

Without `--kubeconfig` and without `KUBECONFIG` the binary asks `spur k8s
kubeconfig --admin`, then the same command under `sudo -n`, then `sudo -n k0s
kubeconfig admin`.

## Test

```sh
make assets    # the tests read the embedded assets
make test
```

The tests hold the Go probes to the capabilities that `capabilities.yaml`
declares, load every profile and chart, and check the variable rules and the
install record arithmetic. `byok/docs/spur-silo-findings.md` keeps the results
of the cluster tests.
