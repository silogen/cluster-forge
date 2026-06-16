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
| `cpu` | `amd-aim-cpu-0.12.0-rc1` | docker.io | `silogenai/*` RC images; optional `dockerhub-regcred` if pulls are private |
| `radeon` | `amd-aim-radeon-0.12.0-rc1` | docker.io | `silogenai/aim-radeon-*` RC tags; optional `dockerhub-regcred` if pulls are private |

`instinct` and `radeon` are GPU families; `cpu` and `epyc` are CPU inference
targets. `cpu` and `radeon` use Docker Hub (`docker.io`) under the `silogenai`
org. When the registry requires auth, the chart references `dockerhub-regcred`
in those namespaces; omit or replace that secret if images are public.

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
