---
status: accepted
date: 2026-09-15
---

# Ship spur-aims as one Go binary with the charts inside it

The first plugin was a bash wrapper around a `bootstrap.sh` script. It needed
`helm`, `kubectl`, `yq` v4, `jq` and `git` on the node, and it cloned
cluster-forge from GitHub for the ref it installs. An operator node behind a
proxy, or a node with no package manager access, cannot do either. The tool
check and `--install-tools` were the answer, and they made the first minutes of
an install a tool install.

`spur-aims` is a Go binary in `byok/spur-aims/`. `go:embed` puts the
profiles, the package metadata, the capability list and every Helm chart of the
release inside it. It installs with the Helm SDK and talks to the cluster with
client-go, so the node needs no tool and no access to GitHub. The only network
need left is the image pull of the cluster itself.

The commands, the install record and the kubeconfig lookup chain are those of
the bash build. The bash build is gone: two implementations of the same
install means that one of them decays without anybody seeing it.

## Considered options

- Keep bash and vendor the charts next to the script. Rejected: the script
  still needs helm, kubectl, yq and jq, which is most of the problem.
- Ship a container image with the tools inside it. Rejected: it needs a
  container runtime that can reach the API server, and the operator then debugs
  a container instead of a command.
- Go with the charts pulled at run time. Rejected: it keeps the GitHub and
  registry dependency that the binary is meant to remove.
- Keep the bash build beside the binary for an install from any cluster-forge
  ref. Rejected on 2026-09-17: nobody ran it after the binary existed, and its
  tests stubbed the tools that the binary does not use.

## Consequences

- There is no `--ref`. An upgrade is an install from a newer binary. A change
  that is not released yet needs a binary built from that branch.
- The binary is about 105 MB, and `make assets` needs helm and the network once
  at build time to resolve the chart dependencies.
- A capability probe exists twice: as a shell command in `capabilities.yaml`,
  which documents the probe and lets a test script run one by hand, and as Go
  code in `probes.go`. A test holds the two lists to the same names.
- A chart change reaches an operator only after a new binary is built. The
  release of `spur-aims` is therefore a cluster-forge release.
- The tests that need no cluster are Go tests, because a stub `helm` or
  `kubectl` on `PATH` never runs under the binary.
