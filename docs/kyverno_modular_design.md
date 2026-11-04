# Modular Kyverno policy design

Each Kyverno policy module is a Helm chart in `sources/kyverno-policies/`
and a separate Argo CD application. Each cluster size enables only the
modules that it needs, in `enabledApps` of `root/values_{small,medium,large}.yaml`.

## Modules

| Module | Application | Small | Medium | Large |
|--------|-------------|-------|--------|-------|
| `base/` | `kyverno-policies-base` | Yes | Yes | Yes |
| `storage-local-path/` | `kyverno-policies-storage-local-path` | No | Yes | No |

### `base/`

- `dynamic-pvc-creation`: makes a user PVC from Deployment or Pod
  annotations. The access mode follows the storage class. Refer to
  [kyverno_access_mode_policy.md](kyverno_access_mode_policy.md).
- `modelcache-download-resource-limits`: sets resource requests and limits
  on model cache download Jobs.

Chart values (`sources/kyverno-policies/base/values.yaml`):

| Value | Default | Purpose |
|-------|---------|---------|
| `dynamicPvc.readWriteManyStorageClasses` | `[]` | StorageClasses that can serve ReadWriteMany. Large sets `[default, mlstorage, multinode]`. |

### `storage-local-path/`

- `local-path-access-mode-mutation`: changes ReadWriteMany and ReadOnlyMany
  to ReadWriteOnce when a PVC is created.
- `local-path-access-mode-warning`: Audit rule that reports PVCs that
  request ReadWriteMany or ReadOnlyMany.

This module is temporary. Medium keeps it only because aim-engine makes
model cache PVCs as ReadWriteMany. Platform PVCs request the correct mode at
the source. Do not add a new dependency on this module.

## Add a module

1. Make a chart in `sources/kyverno-policies/<name>/`.
2. Add tests in `sources/kyverno-policies/<name>/test/`. If the tests need
   chart values, put them in `test/helm-values.yaml`. CI renders the chart
   with this file.
3. Add the chart to the CI matrix in `.github/workflows/helm-chart-checks.yaml`.
4. Add the application to `root/values.yaml` and to `enabledApps` of each
   cluster size that needs it, in alphabetical order.
5. Update `sbom/components.yaml` and run `cd sbom && ./validate-sync.sh`.

## Remove a module from a cluster size

Remove the application from `enabledApps`. The Argo CD Application has no
resources finalizer, so the ClusterPolicies stay on existing clusters.
Delete them manually with `kubectl delete clusterpolicy <name>`.
