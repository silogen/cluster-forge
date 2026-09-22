# BYOK

Installation of the Enterprise AI stack onto a Kubernetes cluster that already exists. Also the home of the `spur-aims` plugin.

## Language

**Profile**:
A named, ordered list of packages installed together, such as `default` or `demo`. A `-cpu` profile is the same profile on a cluster with no GPU. A profile is the unit a user installs or uninstalls.
_Avoid_: level, tier, taso, byok-profile

**Package**:
One umbrella Helm chart installed as one Helm release into its own namespace. A package declares the capabilities it provides and requires.
_Avoid_: app, component, chart

**Capability**:
A named condition on the target cluster, either provided by a package or probed live. Install order and removal checks are based on capabilities.
_Avoid_: dependency, feature

**Profile variable**:
A `key=value` input a profile declares, such as `domain`. Given on the command line as `--var key=value`.
_Avoid_: parameter, option, setting

**Target cluster**:
The Kubernetes cluster a profile is installed on. For `spur-aims` this is the k0s cluster that Spur manages.
_Avoid_: customer cluster, spur cluster

**AIMs plugin**:
The `spur-aims` executable, run as `spur aims`. It obtains the target cluster's admin kubeconfig from Spur and installs a profile with the Helm library, from the charts inside itself.
_Avoid_: silo plugin, inference plugin, forge plugin

**Install record**:
The list of profiles installed on the target cluster, with the source ref of each. `uninstall` removes only packages that no other recorded profile needs.
_Avoid_: state, inventory, bookkeeping
