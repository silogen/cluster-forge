<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# aim-cluster-model-source

Helm chart that installs `AIMClusterModelSource` resources. It renders one of
two mutually exclusive branches, selected by `hardwareFamilies`:

- **Legacy (default):** when `hardwareFamilies` is empty, the chart installs the
  full set of generic `amd-aim-release-*` model sources (versions 0.8.5, 0.9.0,
  0.10.0, 0.11.0), unchanged from the pre-chart directory app.
- **Per-hardware-family profiles:** when `hardwareFamilies` is non-empty, the
  chart installs only the `AIMClusterModelSource` resources for the listed
  families. The legacy generic sources are not installed.

## `hardwareFamilies`

A YAML list (the primary form) or a comma-separated string. Allowed values:
`cpu`, `epyc`, `instinct`, `radeon`. Empty (the default) selects the legacy
branch.

```yaml
hardwareFamilies:
  - epyc
  - instinct
```

| Family | Source name | Registry | Notes |
|---|---|---|---|
| `instinct` | `amd-aim-instinct-0.12.0` | docker.io | works today |
| `epyc` | `amd-aim-epyc-0.11.0` | docker.io | works today |
| `cpu` | `amd-aim-cpu-0.12.0-rc1` | ghcr.io | placeholder, image pull fails until a docker.io release exists |
| `radeon` | `amd-aim-radeon-0.12.0-rc1` | ghcr.io | placeholder, image pull fails until a docker.io release exists |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. `cpu` and `radeon` are only available as `-rc1` on `ghcr.io` and
require the `ghcr-regcred` pull secret, which this cluster does not provision.
They are pinned as placeholders, their pull will fail until the team publishes a
docker.io version.

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
