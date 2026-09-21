# AGENTS.md

This file tells agents how to work in this repository.

## What this repo is

Cluster-Forge is a GitOps payload. It holds Helm charts and an app-of-apps
chart that ArgoCD renders inside a cluster. There is no binary to build and no
bootstrap script here. cluster-bloom does that part. Its
`deploy_clusterforge` role installs ArgoCD and Gitea, pushes this repository
into the in-cluster Gitea, and sets the runtime values (`global.domain`,
`global.clusterSize`, `clusterForge.targetRevision`, image repositories).
cluster-bloom reads this repository at a release tag.

## Architecture

- `root/` is the app-of-apps chart. `root/templates/cluster-apps.yaml` loops
  over `enabledApps` and renders one ArgoCD `Application` per name from the
  matching `apps.<name>` entry in the values. The order comes from `syncWave`
  (-70 to 0).
- `root/values.yaml` is the single source of truth for each app: chart source,
  version, namespace, sync wave, and `valuesFile` / `valuesObject` /
  `helmParameters`. The files `values_small.yaml`, `values_medium.yaml` and
  `values_large.yaml` contain only the differences from the base, and are
  merged over it with `yq eval-all '. as $i ireduce ({}; . * $i)'`. A
  cluster-values overlay repository in Gitea merges on top of that at runtime.
- An app that is declared under `apps:` but is absent from every `enabledApps`
  list renders nothing. This is the mechanism for opt-in apps, for example
  `envoy-ai-gateway-ratelimit`. Enable such an app from the overlay, not here.
- `sources/<app>/` holds the chart that the Application points to. A vendored
  upstream chart sits in a version subdirectory (`sources/argocd/8.3.5`,
  `sources/envoy-gateway/v1.8.1`). An in-house chart sits at the top level
  (`sources/keycloak-config`, `sources/kyverno-policies/base`). Many apps are
  not here at all and pull an OCI chart through `repoURL` and `chart`.
- `root-extras/` is a second app-of-apps for extra components that a user
  supplies, and it reads `extra-apps-values.yaml` from the overlay repository.
  It is separate on purpose. Helm renders a chart all-or-nothing, so a
  malformed extra component cannot break the core Applications. Do not add
  user components to `root/values.yaml`.
- `sbom/components.yaml` mirrors `root/values.yaml` for SBOM generation. CI
  fails if the two files drift apart.

Related documents: `docs/values_inheritance_pattern.md`,
`docs/adding_extra_components.md`, `docs/configuration-reference.md`,
`docs/kyverno_modular_design.md`.

## Commands

You can run each CI check locally with `helm`, `yq` and `kyverno`.

```bash
# Root chart. This must pass for each sizing file.
helm lint ./root -f ./root/values.yaml
helm template ./root -f ./root/values_small.yaml   # also values_medium, values_large

# Tests for the install helpers. These are offline and need no cluster.
scripts/test/run-tests.sh

# Kyverno policy tests for one chart
cd sources/kyverno-policies/base/test
helm template test-release .. > all-resources.yaml
yq eval 'select(.apiVersion == "kyverno.io/v1")' all-resources.yaml > policy.yaml
kyverno test . --detailed-results

# SBOM sync check. Run it in sbom/, because the scripts call each other with ./
cd sbom && ./validate-sync.sh
```

Cut a release by hand from Actions, Release Pipeline, Run workflow. The
pipeline always makes a prerelease.

## Conventions that CI enforces

- If you change `root/values.yaml` (versions, new apps, `enabledApps`), update
  `sbom/components.yaml` in the same change.
- Each chart in `sources/kyverno-policies/` must have `test/kyverno-test.yaml`,
  a minimum of one test resource file, a test result for each `ClusterPolicy`,
  and an entry in the matrix in `.github/workflows/helm-chart-checks.yaml`.
- If you add a configuration variable, write it in
  `docs/configuration-reference.md`.
- Keep `enabledApps` in alphabetical order. It stays a list, so an overlay
  that overrides it must write the full list. Helm replaces lists, but merges
  maps.

## Updating a Helm chart in sources/

A directory in `sources/` holds either a Helm chart or plain Kubernetes
manifests. A vendored upstream chart sits in a version subdirectory, for
example `sources/argocd/8.3.5`. An in-house chart has no version
subdirectory, for example `sources/keycloak-config`.

To move to a new upstream version, add a subdirectory for the new version and
point `apps.<name>.path` in `root/values.yaml` to it. Keep the subdirectory of
the previous version. Do not change it and do not delete it.
