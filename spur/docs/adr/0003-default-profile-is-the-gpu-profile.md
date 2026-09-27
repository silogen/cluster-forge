---
status: accepted
date: 2026-09-17
---

# The default profile is the GPU profile, and the operator selects `-cpu`

`spur aims install` with no profile name installs `default`, the profile for
AMD Instinct GPUs. It holds the AMD GPU operator, turns the accelerator
detector on and takes the Instinct family of the catalog. `--no-gpu` adds
`-cpu` to the profile name, so `install --no-gpu` installs `default-cpu` and
`install demo --no-gpu` installs `demo-cpu`. The flag is refused when the name
already ends with `-cpu`.

The plugin never selects a profile on its own. `install` and `validate` ask
Spur for the GPU of every node and print one warning when the profile and the
GPUs do not go together:

1. A `-cpu` profile on a cluster with Instinct nodes: the GPUs will not be
   used.
2. A GPU profile on a cluster with no GPU: the profile installs the GPU
   operator and the GPU detector, and `--no-gpu` is the flag to give.
3. A GPU that is not Instinct, with any profile: the GPU profile supports
   Instinct only, and the `-cpu` profile is the supported choice on that node.

The warning never changes the name and never stops the command.

The plugin before 2026-09-17 had CPU as the default and selected the GPU
profile from the node resources. That auto-selection existed only because the
default was CPU and the GPU case had to be found. A product that runs on AMD
GPUs installs for AMD GPUs by default, and "no GPU" is then a choice that the
operator makes, not one that the plugin guesses.

## Considered options

- Keep CPU as the default and select the GPU profile from the node resources.
  Rejected: with GPU as the default the selection has no job left, and a
  selection that changes the name in silence hides a choice that the operator
  must know about.
- Refuse the install when the profile and the GPUs do not go together.
  Rejected: the operator can know more than the scan, for example a node that
  Spur has not registered yet, and a refusal takes that choice away.
- Keep a list of Radeon GPU types in the plugin. Rejected: Spur names an
  Instinct card `mi` plus digits, and every other type is an AMD GPU that is
  not Instinct. The negative rule covers RX 9000, older Radeon and every card
  that Spur does not know yet, with no list to maintain.

## Consequences

- A cluster with no GPU needs `--no-gpu`. Without it, `default` installs the
  GPU operator, and the catalog discovery pulls every Instinct model image,
  which fills a small disk. The warning says so before the install.
- `validate` gives the same warning, so an operator can see it with nothing
  installed.
- The GPU classifier is a pure function with a table test in `kube_test.go`.
  The Radeon case has no test on a node yet, see the findings.
- Each GPU profile needs a `-cpu` twin, see ADR-0004.
