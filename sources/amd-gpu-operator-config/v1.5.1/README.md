# amd-gpu-operator-config

Cluster-side configuration for the AMD GPU Operator: the `DeviceConfig` custom
resource plus supporting RBAC and the metrics `gpu-config` ConfigMap.

## GPU stack family selection

`GPU_STACK_FAMILY` selects the DeviceConfig driver train. Cluster Bloom does
not install a host ROCm runtime. The host `amdgpu` package default stays
`31.40.0` for both families. The operator chart is AMD GPU Operator `v1.5.1`
for every family. Cluster Forge pins that chart in `root/values.yaml`.

Values:

| Value | Meaning |
|-------|---------|
| `gpuStackFamily` | `radeon` \| `instinct`. Empty resolves to `instinct` (the current default). |
| `driverVersion` | Explicit DeviceConfig `spec.driver.version` override. When set, wins over the per-family default. |
| `profiles.<family>.driverVersion` | Per-family default ROCm driver version used when `driverVersion` is empty. |
| `gpuSharing.enabled` | `true` adds the DeviceConfig `gpu-operator-dra` with the DRA driver on nodes labelled `spur.amd.com/gpu-sharing=true`, limits the device plugin to nodes labelled `spur.amd.com/gpu-sharing=false`, and adds the DeviceClass `gpu.amd.com` with `extendedResourceName: amd.com/gpu`. Set `draDriver.deviceClass.create=false` in the operator chart, so this chart is the one owner of the class. Default `false`. See `spur/docs/spur-gpu-sharing.md`. |
| `gpuSharing.draDriverImage` | DRA driver image. Default `docker.io/rocm/k8s-gpu-dra-driver:v1.0.1`. |
| `gpuSharing.metricsNodePort` | Node port of the metrics exporter of `gpu-operator-dra`. Default `32501`. |

Resolution precedence (see `templates/_helpers.tpl`, `gpuStack.driverVersion`):

1. `driverVersion` if set (cluster-bloom injects the family-resolved value here),
2. else `profiles[gpuStackFamily].driverVersion`,
3. else the `instinct` profile.

Empty input resolves to `instinct` → `7.0`. `radeon` resolves to `7.13`
(tech preview).

### How the value is injected

cluster-bloom writes `gpuStackFamily` and `driverVersion` into the
cluster-values repository through the `gitea-init-job`. It does not write
`apps.amd-gpu-operator.path` or `apps.amd-gpu-operator-config.path`. Those
paths stay in the Cluster Forge release: `amd-gpu-operator/v1.5.1` and
`amd-gpu-operator-config/v1.5.1`. A path set in cluster-values overrides that
pin, because cluster-values is merged last.

