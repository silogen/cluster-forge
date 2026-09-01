<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs `AIMClusterModelSource` resources. Two mutually
exclusive branches, selected by `hardwareFamilies`:

| `hardwareFamilies` | Template | What is installed |
|---|---|---|
| Empty (`[]`, chart default) | `templates/unfiltered.yaml` | Instinct model sources **0.11.1, 0.12.0, 0.13.0** plus a mixed base catalog (`aim-base`, `aim-epyc-base`, `aim-radeon-base`) |
| Non-empty list | `templates/profiles.yaml` | Only the listed families (see table below) |

cluster-bloom injects a YAML list at install (`AIM_HARDWARE_FAMILY`, auto-detected
when omitted), so a typical new install takes the **profiles** path. Clearing the
list to `[]` in Gitea selects `unfiltered.yaml`.

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
| `instinct` | `amd-aim-release-0.8.5` … `0.11.0`, `amd-aim-instinct-0.11.1`, `0.12.0`, `0.13.0` | `aim-base` 0.11–0.13.1 | Generic `amd-aim-release-*` sources are part of the Instinct profile, not the unfiltered catalog |
| `epyc` | `amd-aim-epyc-0.11.0`, `amd-aim-epyc-0.13.0` | `aim-epyc-base` 0.11, 0.13 | |
| `radeon` | `amd-aim-radeon-0.12.0` | `aim-radeon-base` 0.12 | Preview tags |
| `cpu` | — | — | Placeholder only; no `AIMClusterModelSource` is rendered |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. Registry is `docker.io`.

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
