<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs `AIMClusterModelSource` resources for the selected
hardware families. Each family has its own template file; only listed families
are rendered:

| Template | Family |
|---|---|
| `templates/instinct.yaml` | `instinct` |
| `templates/epyc.yaml` | `epyc` |
| `templates/cpu.yaml` | `cpu` |
| `templates/radeon.yaml` | `radeon` |
| `templates/bases.yaml` | base catalog sources for `instinct`, `epyc`, `radeon` |

## `hardwareFamilies` (required)

A YAML list (the primary form) or a comma-separated string. Allowed values:
`cpu`, `epyc`, `instinct`, `radeon`. **At least one family must be set** —
an empty list fails template rendering (`templates/guard.yaml`).

This guard protects brownfield clusters: without it, an upgrade with empty
`hardwareFamilies` would render zero sources and ArgoCD prune would delete
every existing `AIMClusterModelSource` in the cluster.

```yaml
hardwareFamilies:
  - epyc
  - instinct
```

| Family | Model release source | Base catalog source | Registry | Notes |
|---|---|---|---|---|
| `instinct` | `amd-aim-instinct-0.12.0` (+ release tracks) | `amd-aim-instinct-bases` | docker.io | Base images for AIWB custom model onboarding |
| `epyc` | `amd-aim-epyc-0.11.0` | `amd-aim-epyc-bases` | docker.io | works today |
| `cpu` | `amd-aim-cpu-0.12.0-rc1` | — | docker.io | `silogenai/*` RC images; optional `dockerhub-regcred` if pulls are private |
| `radeon` | `amd-aim-radeon-0.12.0` | `amd-aim-radeon-bases` | docker.io | `silogenai/aim-radeon-*` RC model tags; base uses `amdenterpriseai/aim-radeon-base` |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. `cpu` and `radeon` use Docker Hub (`docker.io`) under the `silogenai`
org. When the registry requires auth, the chart references `dockerhub-regcred`
in those namespaces; omit or replace that secret if images are public.

## Upgrade policy (additive manifest, prune)

The chart manifest is **additive per family**: each sync installs only the
sources for the families listed in `hardwareFamilies`. ArgoCD applies the
rendered manifest with **prune enabled**, so any `AIMClusterModelSource` that
is no longer in the manifest is deleted from the cluster.

When changing `hardwareFamilies` or upgrading the chart:

1. Set the target families explicitly in cluster-values **before** syncing.
2. Expect sources for removed families to be pruned on the next sync.
3. Existing AIM models tied to pruned sources may need redeployment from the
   remaining catalog.

For in-place cluster upgrades from v2.2.x, see
[docs/migrations/v2.2.x-to-v2.4-migration.md](../../docs/migrations/v2.2.x-to-v2.4-migration.md).

## Installing

This chart is normally driven by cluster-bloom via the `AIM_HARDWARE_FAMILY`
install flag, which injects the selected families as a YAML list into
`apps.aim-cluster-model-source.valuesObject.hardwareFamilies` (see the
cluster-forge `root` chart). No comma parsing is involved on that path — the
value travels as a structured list.

For a manual `helm` install, prefer a values file or pass a JSON list. A
comma-separated string also works because the chart splits it, but note that
Helm's `--set` and `--set-string` both treat a comma as a list separator and
will silently drop a multi-value string, so use `--set-json` for the list form:

```bash
helm install ... --set-json 'hardwareFamilies=["epyc","instinct"]'
```

Verify rendering locally:

```bash
# must fail
helm template test sources/aim-cluster-model-source

# per-family smoke checks
helm template test sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct"]'
helm template test sources/aim-cluster-model-source --set-json 'hardwareFamilies=["epyc"]'
helm template test sources/aim-cluster-model-source --set-json 'hardwareFamilies=["radeon"]'
```
