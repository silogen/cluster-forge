# amd-gpu-operator-config

Cluster-side configuration for the AMD GPU Operator: the `DeviceConfig` custom
resource plus supporting RBAC and the metrics `gpu-config` ConfigMap.

## GPU stack family selection

The DeviceConfig out-of-tree driver ROCm version is selected by GPU family so it
matches the host ROCm installed by cluster-bloom and the GPU Operator chart
version. This is driven by cluster-bloom's `GPU_STACK_FAMILY` flag.

Values:

| Value | Meaning |
|-------|---------|
| `gpuStackFamily` | `radeon` \| `instinct`. Empty resolves to `instinct` (the current default). |
| `driverVersion` | Explicit DeviceConfig `spec.driver.version` override. When set, wins over the per-family default. |
| `profiles.<family>.driverVersion` | Per-family default ROCm driver version used when `driverVersion` is empty. |

Resolution precedence (see `templates/_helpers.tpl`, `gpuStack.driverVersion`):

1. `driverVersion` if set (cluster-bloom injects the family-resolved value here),
2. else `profiles[gpuStackFamily].driverVersion`,
3. else the `instinct` profile.

Empty input resolves to `instinct` → `7.0`, so existing installs are unchanged.

### How the value is injected

- **Small clusters:** cluster-bloom renders the parent chart with
  `--set apps.amd-gpu-operator-config.valuesObject.gpuStackFamily=<family>` and
  `--set apps.amd-gpu-operator-config.valuesObject.driverVersion=<version>`.
- **Medium / large clusters:** the `gitea-init-job` writes the same keys into the
  cluster-values repo.

The GPU Operator chart version itself is selected separately via the app-level
`apps.amd-gpu-operator.path` field (a sibling of `valuesObject`), not in this
chart.

