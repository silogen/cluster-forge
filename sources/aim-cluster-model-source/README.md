<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs the AIM model catalog. `hardwareFamilies` selects
which families are installed. `includeProviders` and `excludeProviders`
are regular expressions matched against the image reference. Helm applies
both lists while it renders the chart. `excludeProviders` takes priority.
Two mutually exclusive branches, selected by `hardwareFamilies`:

| `hardwareFamilies` | Template | What is installed |
|---|---|---|
| Empty (`[]`, chart default) | `templates/unfiltered.yaml` | Instinct model sources **0.11.1, 0.12.0, 0.13.0, 2026.11.0**. `aim-base` is always installed. Does **not** install generic `amd-aim-release-*`, `amd-aim-instinct-2026.9.0`, `aim-epyc-base`, or `aim-radeon-base`. |
| Non-empty list | `templates/profiles.yaml` | Only the listed families (see table below). Instinct includes generic `amd-aim-release-*` (0.8.5–0.11.0) plus Instinct **0.11.1, 0.12.0, 0.13.0, 2026.9.0, 2026.11.0**. |

The default `includeProviders` list is `openai`, `mistralai`, `meta`,
`google`, `unsloth`, and `coherelabs`. The default `excludeProviders` list
is `zai-org`, `qwen`, `deepseek-ai`, and `minimaxai`. A source
whose images are all outside that list is omitted. With the default, that
includes `amd-aim-instinct-2026.9.0` and `amd-aim-instinct-2026.11.0`.

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

| Family | Model sources | Notes |
|---|---|---|
| `instinct` | `amd-aim-release-0.8.5` … `0.11.0`, `amd-aim-instinct-0.11.1`, `0.12.0`, `0.13.0`, `2026.9.0`, `2026.11.0` | Generic `amd-aim-release-*` and `amd-aim-instinct-2026.9.0` are part of the Instinct profile, not the unfiltered catalog. Instinct `2026.11.0` is in both catalogs. |
| `epyc` | `amd-aim-epyc-0.11.0`, `amd-aim-epyc-0.13.0` | |
| `radeon` | `amd-aim-radeon-0.12.0`, `amd-aim-radeon-2026.11.0` | `0.12.0` uses preview tags. `2026.11.0` is part of the Radeon profile, not the unfiltered catalog. |
| `cpu` | — | Placeholder only. No model source is rendered. |

Images whose repository name contains `base` are not filtered by provider.
`aim-base` 0.11–0.13.1 plus **2026.9.0** and **2026.9.1** are always installed
in `aim-base-models`. `aim-epyc-base` 0.11 and 0.13 are installed in
`aim-epyc-base-models` only when `epyc` is selected. `aim-radeon-base` 0.12
is installed in `aim-radeon-base-models` only when `radeon` is selected.

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. Registry is `docker.io` (`amdenterpriseai`).

## Provider filters

Each entry is a regular expression. Helm keeps an image when the image
reference matches `includeProviders` and matches no pattern in
`excludeProviders`. A pattern that appears in both lists excludes the image.
For example, `google` matches
`amdenterpriseai/aim-epyc-google-gemma-4-e4b-it`.

| Value | Default | Effect |
|---|---|---|
| `includeProviders` | `openai`, `mistralai`, `meta`, `google`, `unsloth`, `coherelabs` | Patterns that allow an image. |
| `excludeProviders` | `zai-org`, `qwen`, `deepseek-ai`, `minimaxai` | Patterns that block an image. This list takes priority. |

An empty `includeProviders` list installs no model images. Remove a pattern
from `excludeProviders` and add it to `includeProviders` to install matching
images.

Helm omits an `AIMClusterModelSource` when every image in it is dropped.
Base images are outside this filter.

```yaml
includeProviders:
  - meta
  - qwen
excludeProviders:
  - zai-org
```

Cluster Forge passes the same keys through
`apps.aim-cluster-model-source.valuesObject`.

## Installing

This chart is normally driven by cluster-bloom via the `AIM_HARDWARE_FAMILY`
install flag, which injects the selected families as a YAML list into
`apps.aim-cluster-model-source.valuesObject.hardwareFamilies` (see the
cluster-forge `root` chart). No comma parsing is involved on that path — the
value travels as a structured list.

The full-platform Helm install uses the same selection.
`docs/manual_helm_install/full-platform/scripts/aim-catalog.sh` reads
`AIM_HARDWARE_FAMILY` and passes it to `hardwareFamilies`.

For a manual `helm` install, prefer a values file or pass a JSON list. A
comma-separated string also works because the chart splits it, but note that
Helm's `--set` and `--set-string` both treat a comma as a list separator and
will silently drop a multi-value string, so use `--set-json` for the list form:

```bash
helm install ... --set-json 'hardwareFamilies=["epyc","instinct"]'
```

## Demo

```bash
# Default providers. The exclude list stays out.
helm template aim-cluster-model-source sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct","epyc","radeon"]'

# Meta and Qwen. Qwen stays out while it remains in excludeProviders.
helm template aim-cluster-model-source sources/aim-cluster-model-source --set-json 'hardwareFamilies=["instinct","epyc","radeon"]' --set-json 'includeProviders=["meta","qwen"]' --set-json 'excludeProviders=[]'
```
