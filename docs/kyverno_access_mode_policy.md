# Kyverno PVC Access Mode Mutation Policy

This document describes the Kyverno mutating webhook implementation that automatically converts incompatible PersistentVolumeClaim access modes for small and medium clusters using the local-path provisioner.

## Overview

The local-path provisioner (used in small and medium clusters) only supports:
- **ReadWriteOnce (RWO)**: Volume can be mounted as read-write by a single node
- **ReadWriteOncePod (RWOP)**: Volume can be mounted as read-write by a single pod

It does **NOT** support:
- **ReadWriteMany (RWX)**: Volume can be mounted as read-write by many nodes
- **ReadOnlyMany (ROX)**: Volume can be mounted as read-only by many nodes

## Problem Statement

Applications or Helm charts that request RWX or ROX access modes will fail to create PVCs on small/medium clusters, causing deployment failures. This policy automatically converts these unsupported access modes to RWO to ensure compatibility.

## Solution Architecture

### 1. **Deployment-Based Control (Simplified)**

The policy is **ONLY deployed** to clusters that need it:

| Cluster Size | Policy Deployed | Storage Provider | RWX Support |
|--------------|----------------|------------------|-------------|
| Small        | ✅ **YES**     | local-path       | ❌ No       |
| Medium       | ✅ **YES**     | local-path       | ❌ No       |
| Large        | ❌ **NO**      | Longhorn         | ✅ Yes      |

**Key Principle**: *The policy never exists on large clusters*, eliminating any need for runtime size detection.

### 2. **Configuration Control**

#### Small/Medium Clusters (`values_small.yaml`, `values_medium.yaml`)
```yaml
enabledApps:
  - kyverno
  - kyverno-config
  - local-path-access-mode-policies  # ✅ Policy included

apps:
  local-path-access-mode-policies:
    namespace: kyverno
    path: kyverno-config/local-path-access-mode-mutation.yaml
```

#### Large Clusters (`values_large.yaml`)
```yaml
enabledApps:
  - kyverno
  - kyverno-config
  # ❌ local-path-access-mode-policies NOT included

# ❌ No policy app definition at all
```

### 3. **Simplified Kyverno Policy**

The policy has **no cluster size detection logic** - it simply converts all RWX/ROX to RWO:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: local-path-access-mode-mutation
spec:
  rules:
    - name: convert-rwx-rox-to-rwo
      match:
        resources:
          kinds:
            - PersistentVolumeClaim
      preconditions:
        any:
          # Simply check if RWX or ROX is requested
          - key: "{{ request.object.spec.accessModes || [] }}"
            operator: Contains
            value: "ReadWriteMany"
          - key: "{{ request.object.spec.accessModes || [] }}"
            operator: Contains
            value: "ReadOnlyMany"
      mutate:
        patchStrategicMerge:
          spec:
            accessModes:
              - ReadWriteOnce  # Always convert to RWO
```

**No ConfigMaps, no cluster size detection, no complex logic!**

## Implementation Details

### File Structure
```
cluster-forge/
├── sources/kyverno-config/
│   └── local-path-access-mode-mutation.yaml    # Simple policy
├── root/
│   ├── values_small.yaml                       # ✅ Includes policy
│   ├── values_medium.yaml                      # ✅ Includes policy  
│   └── values_large.yaml                       # ❌ Excludes policy
└── scripts/
    └── bootstrap.sh                            # No ConfigMap logic
```

### Bootstrap Script Logic
```bash
# No cluster size detection needed!
# The policy is deployed or not based on values_*.yaml configuration
# Large clusters simply don't include the policy in enabledApps

./scripts/bootstrap.sh example.com --CLUSTER_SIZE=small   # Policy deployed
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=medium # Policy deployed  
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=large  # Policy NOT deployed
```

## Usage Examples

### Deployment Scenarios

#### Small/Medium Cluster
```bash
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small
```
**Result**:
- Kyverno policy **deployed**
- RWX/ROX automatically converted to RWO
- No runtime detection needed

#### Large Cluster  
```bash
./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large
```
**Result**:
- Kyverno policy **NOT deployed at all**
- RWX/ROX work natively with Longhorn
- No policy to interfere or require detection

### Application Examples

#### On Small/Medium Clusters (Policy Active)
```yaml
# Original PVC request
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-storage
spec:
  accessModes:
    - ReadWriteMany    # ❌ Will be converted
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path

# After Kyverno mutation (automatic)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-storage
  annotations:
    kyverno.io/original-access-modes: "ReadWriteMany"
    kyverno.io/mutation-applied: "local-path-rwx-to-rwo"
spec:
  accessModes:
    - ReadWriteOnce    # ✅ Converted to supported mode
  resources:
    requests:
      storage: 10Gi
  storageClassName: local-path
```

#### On Large Clusters (No Policy)
```yaml
# Original PVC request - works unchanged
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-storage
spec:
  accessModes:
    - ReadWriteMany    # ✅ Works natively with Longhorn
  resources:
    requests:
      storage: 10Gi
  storageClassName: longhorn
```

## Monitoring and Troubleshooting

### Verify Policy Deployment
```bash
# Check if policy exists (should only be on small/medium clusters)
kubectl get clusterpolicy local-path-access-mode-mutation

# On small/medium: Policy found
# On large: Error from server (NotFound)
```

### View Policy Status
```bash
# View policy details (only on small/medium)
kubectl describe clusterpolicy local-path-access-mode-mutation

# Check mutations applied
kubectl get pvc -o yaml | grep -A5 "kyverno.io/"
```

### Troubleshooting

#### Policy Deployed on Large Cluster (ERROR)
**Should never happen**, but if it does:
```bash
# Check which values file was used
kubectl get applications -n argocd -o yaml | grep "local-path-access-mode-policies"

# If found, the wrong values_*.yaml was used
# Redeploy with correct size:
./scripts/bootstrap.sh <domain> --CLUSTER_SIZE=large
```

#### Policy NOT Working on Small/Medium Clusters
```bash
# Check if policy is deployed
kubectl get clusterpolicy local-path-access-mode-mutation

# Check ArgoCD application
kubectl get application local-path-access-mode-policies -n argocd

# Check Kyverno logs
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno
```

## Benefits of Simplified Approach

### ✅ Advantages

1. **🎯 Simple Logic**: Policy either exists or doesn't - no complex detection
2. **🛡️ Guaranteed Isolation**: Large clusters can never have the policy
3. **🚀 Zero Runtime Overhead**: No ConfigMap lookups or size detection
4. **📝 Clear Configuration**: Easy to see which clusters get the policy
5. **🔧 Easy Debugging**: No complex conditional logic to troubleshoot
6. **⚡ Faster Deployment**: No extra ConfigMap management
7. **🎨 Clean Architecture**: Separation of concerns at configuration level

### ❌ Alternative Approaches (Why We Didn't Use)

- **Runtime Detection**: Complex ConfigMap logic, potential for misconfiguration
- **Storage Class Detection**: Could interfere with custom storage classes
- **Label-Based**: Requires manual labeling, prone to human error

## Security Considerations

- **Minimal Attack Surface**: Policy only exists where needed
- **No Shared State**: No ConfigMaps to misconfigure or attack
- **Audit Trail**: All mutations clearly logged and annotated
- **Principle of Least Privilege**: Large clusters unaffected by any mutation logic

## Migration Considerations

### Upgrading from Small/Medium to Large
1. **Deploy large cluster configuration**:
   ```bash
   ./scripts/bootstrap.sh <domain> --CLUSTER_SIZE=large
   ```
2. **Policy automatically removed** (not in enabledApps)
3. **Deploy Longhorn** for native RWX support
4. **Review existing PVCs** - may need to recreate for RWX if needed

---

**This is the way** - Simple deployment-based policy control eliminates complexity and ensures large clusters never have unnecessary mutation logic! 🔥