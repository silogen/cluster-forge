---
status: accepted
date: 2026-09-15
---

# Install BYOK profiles through a Spur CLI plugin, not a built-in command

An operator with a Spur cluster wants to install a BYOK profile with one
command, `spur inference install [<profile>]`. Spur is a public open-source
project, and cluster-forge holds every Helm chart and profile. We decided that
Spur gets only a generic plugin mechanism in the kubectl style (`spur <name>`
runs `spur-<name>` from `PATH`), and that the `spur-inference` executable
lives in cluster-forge, in `byok/spur-inference/`. No Silo, AIM or AIWB code
goes into the Spur repository.

## Considered options

- A built-in `spur inference` subcommand in the Spur repository. Rejected: it
  puts AMD product names and Helm dependencies into a public scheduler, and
  every new profile would need a Spur release.
- A generic `spur install <chart>` command that wraps Helm. Rejected: the
  install order, capability checks and the install record are BYOK logic and
  belong next to the packages they describe.

## Consequences

- The Spur plugin mechanism must stay free of Silo knowledge. It passes only
  `SPUR_CONTROLLER_ADDR`, `SPUR_CONF`, `SPUR_BIN`, `SPUR_VERSION` and
  `SPUR_PLUGIN_NAME` to a plugin. A plugin gets the cluster kubeconfig itself
  with `$SPUR_BIN k8s kubeconfig --admin`.
- A new profile ships with a new `spur-inference` release, not a new Spur
  release.
- The Spur side and the cluster-forge side can be released and tested
  independently. `spur-inference` also works when run directly, without
  `spur`.
- The name of the binary is the name of the command. The plugin was
  `spur-silo` until 2026-09-17; it is `spur-inference`, because the command
  says what it installs, not who made it.
