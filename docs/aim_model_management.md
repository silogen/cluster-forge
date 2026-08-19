# AIM Model Management

Reference for how AIM catalog sources are packaged, versioned, and extended on
Cluster Forge clusters.

**Administrators adding models between releases** should follow the procedural
guide [Adding AIM Catalog Models](adding_aim_catalog_models.md).

## Overview

Two layers:

| Layer | Mechanism | When to use |
|-------|-----------|-------------|
| **Packaged baseline** | `aim-cluster-model-source` Helm chart (Argo CD) | Every installation; updated at Cluster Forge release cuts |
| **Inter-release additions** | Gitea `cluster-values` + `aim-cluster-model-source-additional` | Private builds, RCs, or public tags not yet in the packaged chart |

Inter-release additions do not replace the AIM team release process or Platform
packaging workflow.

## Packaged baseline catalog

Cluster Forge installs `aim-cluster-model-source`. Its
`AIMClusterModelSource` resources are selected by `AIM_HARDWARE_FAMILY` from
cluster-bloom (auto-detected when omitted).

The chart renders **per-hardware-family profiles** for `instinct`, `epyc`,
`cpu`, and `radeon`. Only listed families are installed. The former legacy
behaviour (full generic `amd-aim-release-*` catalog when `hardwareFamilies` is
empty) is removed; an empty family list is not supported on new installations.

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

The AIM team maintains canonical lists in
[silogen/aim-build](https://github.com/silogen/aim-build):

- **Model sources** — version-pinned files under `.releases/`
- **Base images** — curated tag list (packaged into the chart at release cut)

The Platform release process incorporates approved manifests into
`sources/aim-cluster-model-source/` at each Cluster Forge release.

Environment-specific rolling snapshots under aim-build `.deployments/` serve
Platform CI environments only. They are not packaged in Cluster Forge.

## Version policy

| Scenario | Policy |
|----------|--------|
| **New installation** | Packaged catalog starts at AIM **0.11.1** and later. Pre-0.11.1 generic release sources are not installed. |
| **Platform upgrade** | New AIM versions are **added**. Older versions are **not** removed automatically. |
| **Catalog cleanup** | Installation owner removes deprecated sources or models when no longer needed. |

There is no automated deprecation schedule. Teams depending on an older AIM
version retain its source until they remove it.

## Inter-release additional catalog

Administrators add sources through Gitea and Argo CD; see
[Adding AIM Catalog Models](adding_aim_catalog_models.md).

Flow:

1. Gitea stores `AIMClusterModelSource` manifests in `cluster-values`.
2. `cluster-forge` creates `aim-cluster-model-source-additional`.
3. AIM Engine discovers images and creates `AIMClusterModel` resources.
4. AI Workbench refreshes its catalog periodically.

### Hardware family and catalog UX

The packaged baseline is family-filtered. Inter-release additions can list any
image, but entries for the wrong accelerator appear as **not deployable** in AI
Workbench. Prefer family-matched images and the `{family}-*.yaml` filename
convention described in the how-to guide.

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

## Responsibilities

| Responsibility | Owner |
|----------------|-------|
| AIM release manifests and base-image lists | AIM team (`aim-build`) |
| Packaging into Cluster Forge | Platform release process |
| Inter-release per-cluster additions | Cluster administrator |
| Removing deprecated catalog entries | Installation owner |

## Related documentation

- [Adding AIM Catalog Models](adding_aim_catalog_models.md) — procedural guide
  for administrators
- [aim-cluster-model-source README](../sources/aim-cluster-model-source/README.md)
  — Helm chart reference
- [Values inheritance pattern](values_inheritance_pattern.md) — how
  `hardwareFamilies` reaches the chart
