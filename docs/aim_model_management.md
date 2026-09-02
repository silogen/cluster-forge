# AIM model catalog lifecycle

Reference for how AIM model catalog sources are packaged, extended, and retired on
Enterprise AI reference stack clusters. This guide is for **cluster operators** who
need to understand catalog behaviour and manage models over the life of a cluster.

It is **not tied to the Cluster Forge release cadence**. Use it whenever you
need to add, replace, or remove catalog entries: private builds, early access
tags, bespoke models, or housekeeping after a platform upgrade.

For step-by-step procedures (Gitea manifests, Argo CD sync, verification), see
[Adding AIM catalog models](adding_aim_catalog_models.md).

## Overview

The catalog has two complementary layers:

| Layer | Mechanism | Typical use |
|-------|-----------|-------------|
| **Packaged baseline** | `aim-cluster-model-source` Helm chart (Argo CD) | Default AMD catalog for the cluster hardware family; refreshed when you upgrade Cluster Forge |
| **Cluster-managed additions** | Gitea `cluster-values` + `aim-cluster-model-source-additional` | Any extra model or base images you choose to expose — RCs, private builds, site-specific tags, or images not yet in the packaged chart |

Cluster-managed additions do not replace the packaged baseline that ships with the
cluster; the baseline keeps arriving and updating through Cluster Forge releases.
Additions are an **operator-controlled extension** on top of it, available at any
time.

## Packaged baseline catalog

Cluster Forge installs the in-tree Helm chart `sources/aim-cluster-model-source`.
`AIMClusterModelSource` resources are selected by `hardwareFamilies`, which
cluster-bloom sets from `AIM_HARDWARE_FAMILY`.

| `hardwareFamilies` | Template | Result |
|--------------------|----------|--------|
| Non-empty list (`instinct`, `epyc`, `cpu`, `radeon`) | `templates/profiles.yaml` | Only listed families. The Instinct profile includes generic `amd-aim-release-*` sources (0.8.5–0.11.0) plus Instinct 0.11.1+. `cpu` is a placeholder and renders no sources. |
| Empty list (`[]`, chart default) | `templates/unfiltered.yaml` | Instinct **0.11.1, 0.12.0, 0.13.0** plus mixed base images (`aim-base`, `aim-epyc-base`, `aim-radeon-base`). |

`AIM_HARDWARE_FAMILY` has no default. cluster-bloom injects `hardwareFamilies`
only when the install sets it, so an install that leaves it unset takes the
**unfiltered** path. Set `AIM_HARDWARE_FAMILY` in `bloom.yaml` to get a
family-filtered catalog:

```yaml
AIM_HARDWARE_FAMILY: "instinct"
```

Clearing `hardwareFamilies` to `[]` in Gitea on an existing cluster switches it
back to **unfiltered**; it does not fail chart rendering. See the
[aim-cluster-model-source README](../sources/aim-cluster-model-source/README.md).

### Model release sources vs base catalog sources

| Kind | Purpose | Example source name | Example images it lists |
|------|---------|---------------------|-------------------------|
| **Model release source** | Version-pinned model-specific images for a hardware family | `amd-aim-instinct-0.12.0` | `amdenterpriseai/aim-google-gemma-3-1b-it:0.12.0`, `amdenterpriseai/aim-zai-org-glm-4-7:0.12.0` |
| **Model release source** | Same, EPYC family | `amd-aim-epyc-0.13.0` | `amdenterpriseai/aim-epyc-qwen-qwen3-8b:0.13.0` |
| **Base catalog source** | Generic base images for AI Workbench custom model onboarding (runtime AIM ID) | `aim-base-models` | `amdenterpriseai/aim-base:0.13.1`, `amdenterpriseai/aim-epyc-base:0.13`, `amdenterpriseai/aim-radeon-base:0.12` |

Source names such as `amd-aim-instinct-0.12.0` are `AIMClusterModelSource`
resource names, not image references. The images each source lists are fully
qualified `repository/name:tag` values, as in the last column.

Model release sources list **model-specific** images. Base catalog sources list
**base** images only.

Bases are split **by hardware family** in the packaged chart so AI Workbench
does not show large numbers of not-deployable entries on clusters without
matching hardware.

Each family profile installs only its own base images: Instinct → `aim-base`,
EPYC → `aim-epyc-base`, Radeon → `aim-radeon-base`. The `unfiltered` template is
the one exception — it installs all three, because it has no family to filter
on.

### Source of truth

Canonical model source and base-image lists live in an AMD-internal repository
that operators cannot access. There is no automated feed from it into a
cluster. Those lists are copied into
`sources/aim-cluster-model-source/templates/` by hand when a Cluster Forge
release is prepared. The chart templates in a given release are therefore a
**point-in-time snapshot**, not a live mirror: an AIM version published after
that release does not appear in the packaged baseline until a later Cluster
Forge release picks it up.

For a cluster, the operator-visible source of truth is
`sources/aim-cluster-model-source/` in the Cluster Forge release you installed.
To read the catalog it will install before you deploy, render the chart:

```bash
helm template aim-cluster-model-source sources/aim-cluster-model-source \
  --set-json 'hardwareFamilies=["instinct"]' | grep -E '^  name:'
```

If you need an AIM version sooner than the next Cluster Forge release, use
[cluster-managed additions](#cluster-managed-catalog-additions) — that is the
only path that does not wait on packaging.

Environment-specific CI snapshots are not packaged in Cluster Forge.

## Version policy

| Scenario | Policy |
|----------|--------|
| **New installation, `AIM_HARDWARE_FAMILY` set** | Injects a non-empty list → **profiles** branch. The Instinct profile installs generic `amd-aim-release-*` 0.8.5–0.11.0 alongside `amd-aim-instinct-*` 0.11.1, 0.12.0, 0.13.0, so such an install starts with all of them. |
| **New installation, `AIM_HARDWARE_FAMILY` unset** | Nothing is injected → chart default `[]` → **unfiltered** catalog. |
| **Empty `hardwareFamilies` in Gitea** | **unfiltered** catalog: Instinct 0.11.1+ only (no generic 0.8.x–0.11.0 sources). |
| **Platform upgrade** | New AIM versions are **added**. Older versions are **not** removed automatically. |
| **Catalog cleanup** | Manual. The cluster operator removes deprecated sources; nothing expires on its own. |

There is no automated deprecation schedule. An older AIM version stays in the
catalog until its `AIMClusterModelSource` is deleted. Narrowing a filter is not
enough — see [Filter removal vs source removal](#filter-removal-vs-source-removal).

This applies to cluster-managed additions. Packaged baseline sources are owned
by the `aim-cluster-model-source` chart and are restored by the next Argo CD
sync if deleted in the cluster. The chart's only selector is `hardwareFamilies`,
which switches whole family profiles; it cannot drop an individual packaged
version. Packaged source names (`amd-aim-instinct-0.12.0`,
`amd-aim-epyc-0.13.0`, and so on) are therefore a **stable API**: a Cluster
Forge release adds tracks; it does not delete source names from the chart.

## Cluster-managed catalog additions

Cluster operators add or remove sources through Gitea and Argo CD; see
[Adding AIM catalog models](adding_aim_catalog_models.md).

`aim-cluster-model-source-additional` is not shipped in Cluster Forge. The
operator defines it once in Gitea `cluster-values` (`enabledApps` plus an `apps`
entry) before this path is available — see
[One-time setup](adding_aim_catalog_models.md#one-time-setup).

Typical lifecycle, once it is enabled:

1. Gitea stores `AIMClusterModelSource` manifests in `cluster-values`.
2. The `cluster-forge` parent application creates `aim-cluster-model-source-additional`.
3. AIM Engine discovers images and creates `AIMClusterModel` resources.
4. AI Workbench refreshes its catalog periodically.

Use this path whenever the packaged baseline does not include the image you
need — regardless of whether a Cluster Forge upgrade is planned.

### Hardware family and catalog UX

The packaged baseline is family-filtered when `hardwareFamilies` is non-empty.
Cluster-managed additions can list any image, but entries for the wrong
accelerator appear as **not deployable** in AI Workbench. Prefer family-matched
images and the `{family}-*.yaml` filename convention described in
[Add a model](adding_aim_catalog_models.md#add-a-model).

## Filter removal vs source removal

AIM Engine discovery is append-only. Two edits that look similar in YAML have
opposite runtime effects:

| Action | What happens | Running deployments |
|--------|--------------|---------------------|
| Drop an image from `spec.filters` (or `spec.images`) on an existing source | Already-discovered `AIMClusterModel` resources **stay**. The catalog can keep showing the old image. | Unaffected |
| Delete the `AIMClusterModelSource` (Gitea manifest + Argo CD prune, or drop the source **name** from the packaged chart) | The CR is deleted. Kubernetes garbage-collects every `AIMClusterModel` it owned. | **Can break** workloads that still use those models |

A “hollow shell” — keep the source CR but empty the filter list — **does not
work**. The `AIMClusterModelSource` CRD requires at least one entry in
`spec.filters` or `spec.images` (`MinItems=1`), so empty filters fail
validation.

**To retire a model you actually want gone**, delete the source (and sync with
prune), as in
[Replace or remove a source](adding_aim_catalog_models.md#replace-or-remove-a-source).
You do not delete `AIMClusterModel` resources separately.

**To keep running deployments** while stopping new discoveries of an image,
leave the source name in place and stop listing that image. Expect catalog
clutter until a later source deletion.

**Do not delete packaged source names** from `sources/aim-cluster-model-source`
between Cluster Forge releases. Retire a track by adding a new source; leaving
the old name is what keeps existing clusters from having their models
garbage-collected on the next chart sync.

## Lifecycle constraints

- **Discovery is additive** — adding a filter can create another
  `AIMClusterModel`.
- **Removing a filter does not remove discovered models** — see above.
- **Removing the additional Argo CD Application does not delete its resources**
  — child apps lack a cascading-resources finalizer.
- **Deleting an `AIMClusterModelSource` garbage-collects its owned models.**

Remove or replace source manifests while the additional application still
exists. Disable the application only after sources are pruned.

When upgrading Cluster Forge, review the incoming packaged catalog and remove
cluster-managed manifests that duplicate newly packaged models or bases before
syncing — see
[Before a platform upgrade](adding_aim_catalog_models.md#before-a-platform-upgrade).

## Responsibilities

| Responsibility | Owner |
|----------------|-------|
| Packaged baseline catalog (what a new cluster gets) | The Cluster Forge release you installed |
| Choosing `AIM_HARDWARE_FAMILY` at install | Whoever runs cluster-bloom |
| Cluster-managed catalog additions and removals | Cluster operator |
| Removing deprecated catalog entries | Cluster operator |

## Related documentation

- [Adding AIM catalog models](adding_aim_catalog_models.md) — procedural guide
  for cluster operators
- [aim-cluster-model-source README](../sources/aim-cluster-model-source/README.md)
  — Helm chart reference
- [Values inheritance pattern](values_inheritance_pattern.md) — how
  `hardwareFamilies` reaches the chart
