# Small Cluster Storage Class Configuration

This document explains the storage class configuration strategy for small clusters using `local-path` provisioner.

## Problem Statement

Small clusters use the `local-path` storage provisioner, but many components request:
- `storageClassName: default` - a SC that doesn't exist
- `storageClassName: multinode` - for distributed storage that doesn't exist in small clusters
- `accessModes: [ReadWriteMany, ReadOnlyMany]` - not supported by local-path

## Solution: Two-Part Strategy

### Part 1: Values Overrides (values_small.yaml)

**Components that CAN be overridden** via values.yaml:

| Component | Override Path | Status |
|-----------|--------------|--------|
| airm-infra-cnpg | `storage.storageClass` + `walStorage.storageClass` | ✅ Added |
| aiwb-infra-cnpg | `storage.storageClass` + `walStorage.storageClass` | ✅ Added |
| airm-infra-rabbitmq | `persistence.storageClassName` | ✅ Added |
| grafana | `persistence.storageClassName` | ✅ Already configured |
| minio-tenant | `tenant.pools[].storageClassName` | ✅ Already configured |
| openbao | `server.dataStorage.storageClass` | ✅ Already configured |
| prometheus | `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName` | ✅ Already configured |

**Configuration in [values_small.yaml](root/values_small.yaml)**:
```yaml
apps:
  airm-infra-cnpg:
    valuesObject:
      storage:
        storageClass: local-path
      walStorage:
        storageClass: local-path
  
  airm-infra-rabbitmq:
    valuesObject:
      persistence:
        storageClassName: local-path
  # ... etc
```

### Part 2: Kyverno Policy for Hardcoded Templates

**Components that CANNOT be overridden** (hardcoded templates in sources):

| Component | Why Not Overridable | Hardcoded Class | Solution |
|-----------|---------------------|-----------------|----------|
| keycloak-old | Template has `storageClass: default` | `default` | ⚠️ Kyverno mutation |
| kaiwo-config | Static PVC YAML file | `multinode` | ⚠️ Kyverno mutation |
| otel-lgtm-stack | Template has `storageClassName: default` | `default` | ⚠️ Kyverno mutation |

**Kyverno Policy**: [kyverno-policies-storage-local-path](sources/kyverno-policies/storage-local-path/)

This policy includes TWO mutations:

1. **Access Mode Mutation** ([access-mode-mutation.yaml](sources/kyverno-policies/storage-local-path/templates/access-mode-mutation.yaml))
   - Converts `ReadWriteMany` (RWX) → `ReadWriteOnce` (RWO)
   - Converts `ReadOnlyMany` (ROX) → `ReadWriteOnce` (RWO)
   - Adds annotations for tracking

2. **Storage Class Mutation** ([storageclass-mutation.yaml](sources/kyverno-policies/storage-local-path/templates/storageclass-mutation.yaml))
   - Converts `storageClassName: default` → `local-path`
   - Converts `storageClassName: multinode` → `local-path`
   - Adds annotations for tracking

## Deployment

The Kyverno policy is **ONLY deployed** to small/medium clusters:

```yaml
# values_small.yaml
enabledApps:
  - kyverno-policies-storage-local-path  # ✅ Included

# values_large.yaml (does NOT include this policy)
```

## Why Not Modify Sources?

**Sources directory cannot be modified** because:
1. It contains upstream Helm charts and templates
2. Changes would be overwritten during updates
3. It breaks the separation between configuration (root/) and source charts (sources/)
4. Makes upgrades difficult

## Verification

Check that PVCs are being created successfully:

```bash
# Check for pending PVCs
kubectl get pvc -A | grep Pending

# Check Kyverno policy status
kubectl get clusterpolicy

# View a mutated PVC to see annotations
kubectl get pvc <pvc-name> -n <namespace> -o yaml | grep kyverno.io
```

## Summary

- **Prefer values overrides** when possible (components in Part 1)
- **Use Kyverno mutation** as a fallback for hardcoded templates (components in Part 2)
- **Benefits**: 
  - No source modifications required
  - Automatic handling of components that can't be configured
  - Clear separation of concerns
  - Easy to remove policy on large clusters
