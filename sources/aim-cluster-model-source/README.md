<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs `AIMClusterModelSource` resources. It renders one of
two mutually exclusive branches, selected by `hardwareFamilies`:

- **Legacy (default):** when `hardwareFamilies` is empty, `templates/legacy.yaml`
  installs Instinct model sources **0.11.1, 0.12.0, 0.13.0** plus mixed base
  images (`aim-base` including **2026.9.0** and **2026.9.1**, `aim-epyc-base`,
  `aim-radeon-base`). It does **not** install generic `amd-aim-release-*`
  sources or `amd-aim-instinct-2026.9.0`.
- **Per-hardware-family profiles:** when `hardwareFamilies` is non-empty,
  `templates/profiles.yaml` installs only the listed families. The Instinct
  profile includes generic `amd-aim-release-*` (0.8.5–0.11.0) plus Instinct
  **0.11.1, 0.12.0, 0.13.0, 2026.9.0**.

## `hardwareFamilies`

A YAML list (the primary form) or a comma-separated string. Allowed values:
`cpu`, `epyc`, `instinct`, `radeon`. Empty (the default) selects the legacy
branch.

```yaml
hardwareFamilies:
  - epyc
  - instinct
```

| Family | Packaged source names | Registry | Notes |
|---|---|---|---|
| `instinct` | `amd-aim-release-*` 0.8.5–0.11.0, `amd-aim-instinct-0.11.1`, `0.12.0`, `0.13.0`, `2026.9.0` | docker.io | `amdenterpriseai/*`. The 2026.9.0 model source is profiles-only. |
| `epyc` | `amd-aim-epyc-0.11.0`, `amd-aim-epyc-0.13.0` | docker.io | `amdenterpriseai/aim-epyc-*` |
| `cpu` | *(none)* | — | Placeholder; renders no sources. |
| `radeon` | `amd-aim-radeon-0.12.0` | docker.io | `amdenterpriseai/aim-radeon-*` |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. Images are on Docker Hub (`docker.io`) under `amdenterpriseai`.

## Installing

This chart is normally driven by cluster-bloom via the `AIM_HARDWARE_FAMILY`
install flag, which injects the selected families as a YAML list into
`apps.aim-cluster-model-source.valuesObject.hardwareFamilies` (see the
cluster-forge `root` chart). No comma parsing is involved on that path, the
value travels as a structured list.

For a manual `helm` install, prefer a values file or pass a JSON list. A
comma-separated string also works because the chart splits it, but note that
Helm's `--set` and `--set-string` both treat a comma as a list separator and
will silently drop a multi-value string, so use `--set-json` for the list form:

```bash
helm install ... --set-json 'hardwareFamilies=["epyc","instinct"]'
```
