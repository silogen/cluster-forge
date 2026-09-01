# AIM model catalog lifecycle

Reference for how AIM model catalog sources are packaged, extended, and retired on
Enterprise AI reference stack clusters. This guide is for **cluster operators and platform
administrators** who need to understand
catalog behaviour and manage models over the life of a cluster.

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

Cluster-managed additions do not replace the AIM team release process or Platform
packaging workflow. They are an **operator-controlled extension** of the catalog,
available at any time.

## Packaged baseline catalog

Cluster Forge installs the in-tree Helm chart `sources/aim-cluster-model-source`.
`AIMClusterModelSource` resources are selected by `hardwareFamilies`, which
cluster-bloom sets from `AIM_HARDWARE_FAMILY` (auto-detected when omitted).

| `hardwareFamilies` | Template | Result |
|--------------------|----------|--------|
| Non-empty list (`instinct`, `epyc`, `cpu`, `radeon`) | `templates/profiles.yaml` | Only listed families. The Instinct profile includes generic `amd-aim-release-*` sources (0.8.5–0.11.0) plus Instinct 0.11.1+. `cpu` is a placeholder and renders no sources. |
| Empty list (`[]`, chart default) | `templates/unfiltered.yaml` | Instinct **0.11.1, 0.12.0, 0.13.0** plus mixed base images (`aim-base`, `aim-epyc-base`, `aim-radeon-base`). |

A typical new cluster-bloom install injects a non-empty list, so it uses
**profiles**. Clearing `hardwareFamilies` to `[]` in Gitea switches to
**unfiltered**; it does not fail chart rendering. See the
[aim-cluster-model-source README](../sources/aim-cluster-model-source/README.md).

### Model release sources vs base catalog sources

| Kind | Purpose | Examples |
|------|---------|----------|
| **Model release source** | Version-pinned model-specific images for a hardware family | `amd-aim-instinct-0.12.0`, `amd-aim-epyc-0.13.0` |
| **Base catalog source** | Generic base images for AI Workbench custom model onboarding (runtime AIM ID) | `amdenterpriseai/aim-base`, `amdenterpriseai/aim-epyc-base`, `amdenterpriseai/aim-radeon-base` |

Model release sources list **model-specific** images. Base catalog sources list
**base** images only.

Bases are split **by hardware family** in the packaged chart so AI Workbench
does not show large numbers of not-deployable entries on clusters without
matching hardware.

When ROCm ships multi-hardware base images in a future release, family gating
for bases may be relaxed. Until then, each family profile installs only its own
base images (Instinct → `aim-base`, EPYC → `aim-epyc-base`, Radeon →
`aim-radeon-base`, and so on).

### Source of truth

The AIM team maintains canonical model source and base-image lists in the
[public AIM build repository](https://github.com/amd-enterprise-ai/aim-build).
Those lists are published into the `aim-cluster-model-source` Helm chart for
clusters to consume.

The Platform release process incorporates approved manifests into
`sources/aim-cluster-model-source/` at each Cluster Forge release.

Environment-specific CI snapshots are not packaged in Cluster Forge.

## Version policy

| Scenario | Policy |
|----------|--------|
| **New installation (cluster-bloom)** | Auto-detect or explicit `AIM_HARDWARE_FAMILY` injects a non-empty list → **profiles** branch. Instinct profile still includes generic `amd-aim-release-*` 0.8.5–0.11.0. |
| **Empty `hardwareFamilies` in Gitea** | **unfiltered** catalog: Instinct 0.11.1+ only (no generic 0.8.x–0.11.0 sources). |
| **Platform upgrade** | New AIM versions are **added**. Older versions are **not** removed automatically. |
| **Catalog cleanup** | Installation owner removes deprecated sources or models when no longer needed. |

There is no automated deprecation schedule. Teams depending on an older AIM
version retain its source until they remove it.

## Cluster-managed catalog additions

Operators add or remove sources through Gitea and Argo CD; see
[Adding AIM catalog models](adding_aim_catalog_models.md).

Typical lifecycle:

1. Gitea stores `AIMClusterModelSource` manifests in `cluster-values`.
2. `cluster-forge` creates `aim-cluster-model-source-additional`.
3. AIM Engine discovers images and creates `AIMClusterModel` resources.
4. AI Workbench refreshes its catalog periodically.

Use this path whenever the packaged baseline does not include the image you
need — regardless of whether a Cluster Forge upgrade is planned.

### Hardware family and catalog UX

The packaged baseline is family-filtered when `hardwareFamilies` is non-empty.
Cluster-managed additions can list any image, but entries for the wrong
accelerator appear as **not deployable** in AI Workbench. Prefer family-matched
images and the `{family}-*.yaml` filename convention described in the how-to
guide.

## Lifecycle constraints

- **Discovery is additive** — adding a filter can create another
  `AIMClusterModel`.
- **Removing a filter does not remove discovered models** — delete and replace
  the source, or remove its manifest and sync with prune.
- **Removing the additional Argo CD Application does not delete its resources**
  — child apps lack a cascading-resources finalizer.
- **Deleting an `AIMClusterModelSource` garbage-collects its owned models.**

Remove or replace source manifests while the additional application still
exists. Disable the application only after sources are pruned.

When upgrading Cluster Forge, review the incoming packaged catalog and remove
cluster-managed manifests that duplicate newly packaged models or bases before
syncing — see the how-to guide.

## Responsibilities

| Responsibility | Owner |
|----------------|-------|
| AIM release manifests and base-image lists | AIM team |
| Packaging into Cluster Forge | Platform release process |
| Cluster-managed catalog additions and removals | Cluster / installation operator |
| Removing deprecated catalog entries | Installation owner |

## Related documentation

- [Adding AIM catalog models](adding_aim_catalog_models.md) — procedural guide
  for operators
- [aim-cluster-model-source README](../sources/aim-cluster-model-source/README.md)
  — Helm chart reference
- [Values inheritance pattern](values_inheritance_pattern.md) — how
  `hardwareFamilies` reaches the chart
