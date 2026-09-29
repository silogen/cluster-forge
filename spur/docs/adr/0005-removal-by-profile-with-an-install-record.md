---
status: accepted
date: 2026-09-17
---

# Install and remove by profile, with a record in the cluster and a question first

Every install writes the profile name, the ref of the binary, the time, the
variables and the packages that went on into the ConfigMap `install-record`
in the namespace `aims-system`. An install that stops part way writes the
packages that did go on, marks the record partial, and `status` names the
command that removes them.

`uninstall <profile>` reads the record and removes the packages of that
profile in reverse install order. A package that another recorded profile also
holds stays on the cluster, and so does every CRD that such a package ships.
A namespace goes once, after the last package of that namespace is gone, and
never when a package that stays holds it. `uninstall` refuses to remove a
package that another installed package needs.

Before the first removal `uninstall` prints, for every profile of the run,
what goes, what stays, what is not installed, and the namespaces that the
purge deletes with their PVCs. Then it asks `Remove? [y/N]`. `--yes` skips
the question. When stdin is not a terminal and `--yes` is absent, the command
refuses. A blank name removes every recorded profile, a child before its base.

`install` refuses a profile when another recorded profile holds some of its
packages. An install of the same name is an upgrade and goes through. A
profile that extends the recorded one goes through too.

## Considered options

- Remove single packages. Rejected: a package is one Helm release, but the
  order, the namespaces and the CRDs are shared between packages. The profile
  is the unit that an operator installs, so it is the unit that an operator
  removes. To add and remove an optional package, put it in a profile that
  extends the installed one, as `test-s3` does.
- No record, read the state from the cluster. Rejected: the releases say what
  is installed, not which profile put it there, so a removal cannot know what
  another profile still needs. The capability probes stay, so an install on a
  cluster that another tool touched still does the right thing.
- Remove without a question, as the bash build did. Rejected: a blank name
  now removes everything, with the PVCs. An `uninstall` destroys nothing before
  it has shown what goes and has received a yes.
- Read a pipe as a yes. Rejected: a script must say `--yes`, so that a
  removal in a pipeline is a decision that somebody wrote down.
- Let a second profile go on over the packages of a recorded one. Rejected:
  on a GPU node, `install --no-gpu` over `default` recorded both names, and
  the CPU values went over the charts of the GPU install. Two profiles over
  the same packages cannot be removed one at a time.

## Consequences

- The namespace `aims-system` stays after every uninstall. It holds the
  record only.
- A profile that a newer binary no longer knows can still be removed, because
  the record holds its package list.
- The removal plan is a pure function over the record, the profile and an
  `installed(pkg)` answer, so `record_test.go` tests it without a cluster.
- `uninstall` in a test or a script always takes `--yes`.
