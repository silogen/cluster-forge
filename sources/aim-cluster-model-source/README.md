<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs `AIMClusterModelSource` resources. Two mutually
exclusive branches, selected by `hardwareFamilies`:

| `hardwareFamilies` | Template | What is installed |
|---|---|---|
| Empty (`[]`, chart default) | `templates/unfiltered.yaml` | Instinct model sources **0.11.1, 0.12.0, 0.13.0** plus mixed bases (`aim-base` including **2026.9.0** and **2026.9.1**, `aim-epyc-base`, `aim-radeon-base`). Does **not** install generic `amd-aim-release-*` or `amd-aim-instinct-2026.9.0`. |
| Non-empty list | `templates/profiles.yaml` | Only the listed families (see table below). Instinct includes generic `amd-aim-release-*` (0.8.5–0.11.0) plus Instinct **0.11.1, 0.12.0, 0.13.0, 2026.9.0**. |

cluster-bloom injects a YAML list at install from `AIM_HARDWARE_FAMILY`. That
setting has no default and is injected only when set, so an install that leaves
it unset falls through to the chart default `[]` and takes the **unfiltered**
path. Clearing the list to `[]` in Gitea also selects `unfiltered.yaml`.

## `hardwareFamilies`

A YAML list (the primary form) or a comma-separated string. Allowed values:
`cpu`, `epyc`, `instinct`, `radeon`.

```yaml
hardwareFamilies:
  - epyc
  - instinct
```

| Family | Model sources | Base images | Notes |
|---|---|---|---|
| `instinct` | `amd-aim-release-0.8.5` … `0.11.0`, `amd-aim-instinct-0.11.1`, `0.12.0`, `0.13.0`, `2026.9.0` | `aim-base` 0.11–0.13.1, **2026.9.0**, **2026.9.1** | Generic `amd-aim-release-*` and `amd-aim-instinct-2026.9.0` are part of the Instinct profile, not the unfiltered catalog |
| `epyc` | `amd-aim-epyc-0.11.0`, `amd-aim-epyc-0.13.0` | `aim-epyc-base` 0.11, 0.13 | |
| `radeon` | `amd-aim-radeon-0.12.0` | `aim-radeon-base` 0.12 | Preview tags |
| `cpu` | — | — | Placeholder only; no `AIMClusterModelSource` is rendered |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. Registry is `docker.io` (`amdenterpriseai`).

## `modelFilters`

Helm applies these values while it renders the chart. Each rendered filter
keeps the `image` field only. The `AIMClusterModelSource` spec does not gain
new fields.

| Value | Default | Effect |
|---|---|---|
| `excludedOrigins` | `[]` | Drop a model whose `origin` is in this list. An empty list keeps every origin. |
| `maxParameterBillions` | `0` | Drop a model whose total parameter count is greater than this number. `0` disables the check. |

A model stays when it passes both checks. A count equal to `maxParameterBillions` stays. `parameterBillions` in `model-attributes.yaml` is the published total, rounded to the nearest integer. A mixture-of-experts model uses that total, not the active count. Gemma E4B entries use the published total (about 8).

`origin` is an ISO 3166-1 alpha-2 code. Origins in the attribute file: `CA`, `CN`, `FR`, `US`.

```yaml
modelFilters:
  excludedOrigins:
    - CN
  maxParameterBillions: 30
```

Helm omits an `AIMClusterModelSource` when every image in it is dropped. `spec.filters` must contain at least one image. Base sources named `aim-base-models` are outside this filter.

Add a repository to `model-attributes.yaml` when you add its image to a template. `helm template` fails when an image has no entry.

Cluster Forge passes the same keys through
`apps.aim-cluster-model-source.valuesObject.modelFilters`.

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

## Demo

```bash
# All models for all families
helm template aim-cluster-model-source sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct","epyc","radeon"]'

# All models for all families. Exclude CN & FR models
helm template aim-cluster-model-source sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct","epyc","radeon"]' --set-json 'modelFilters={"excludedOrigins":["CN","FR"]}'

# All models for all families. Exclude CN & FR models and models bigger than 20b
helm template aim-cluster-model-source sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct","epyc","radeon"]' --set-json 'modelFilters={"excludedOrigins":["CN","FR"],"maxParameterBillions":20}'
```
