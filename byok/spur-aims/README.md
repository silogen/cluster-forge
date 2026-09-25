# spur-aims

`spur-aims` installs an AMD Enterprise AI profile on the Kubernetes
cluster that Spur manages. Spur finds it on PATH and runs it as
`spur aims ...`.

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

### Windows WSL

If the WSL PATH includes the Rancher Desktop `bin` directory, helm finds
`docker-credential-secretservice` and uses it. WSL has no Secret Service
daemon, so `make assets` stops before it pulls the OCI charts. Tell helm to
use the Windows credential helper:

```sh
sudo apt install libsecret-1-0
jq '.credsStore = "wincred.exe"' ~/.config/helm/registry/config.json > /tmp/h.json && mv /tmp/h.json ~/.config/helm/registry/config.json
```

Then `~/.config/helm/registry/config.json` contains:

```json
{
  "auths": {},
  "credsStore": "wincred.exe"
}
```

The version string comes from `REF`, which defaults to the current branch:

```sh
make build REF=v1.2.3
```

## Use

```sh
spur aims list
spur aims install                  # the default profile, on AMD Instinct GPUs
spur aims install --no-gpu         # default-cpu, on a cluster with no GPU
spur aims install demo --var domain=example.com \
  --var gatewayServiceType=LoadBalancer --var gatewayExternalIP=10.0.0.10
spur aims status
spur aims uninstall demo --yes
spur aims uninstall                # every recorded profile, after a question
```

A blank profile name is `default`. `--no-gpu` adds `-cpu` to the name, so
`install --no-gpu` installs `default-cpu` and `install demo --no-gpu` installs
`demo-cpu`. The binary never selects a profile on its own. It asks Spur for the
GPU of every node and gives a warning when the profile and the GPUs do not go
together: a `-cpu` profile on Instinct nodes, a GPU profile on a cluster with
no GPU, or a GPU that is not Instinct.

`uninstall` shows what goes, what stays and which namespaces the purge
deletes, then asks `Remove? [y/N]`. `--yes` skips the question. When stdin is
not a terminal and `--yes` is absent, the command refuses before it touches
the cluster. Without a name it removes every recorded profile, a profile that
extends another recorded profile before its base.

The binary writes an install record into the ConfigMap `install-record` of the
namespace `aims-system`, one entry per profile. `uninstall` reads it and
keeps every package that another recorded profile holds.

Without `--kubeconfig` and without `KUBECONFIG` the binary asks `spur k8s
kubeconfig --admin`, then the same command under `sudo -n`, then `sudo -n k0s
kubeconfig admin`.

## Test

```sh
make assets    # most tests read the embedded assets
make test
```

The tests hold the Go probes to the capabilities that `capabilities.yaml`
declares, load every profile and chart, check the variable rules, the profile
format and the install record arithmetic, and hold every `-cpu` profile to its
GPU twin. `byok/tests/optional-package-cycle.sh` needs a cluster and the built
binary. `byok/docs/spur-aims-findings.md` keeps the results of the
cluster tests.
