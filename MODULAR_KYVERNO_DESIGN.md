# Modular Kyverno Policy Design Pattern

This document describes the scalable, modular design pattern for Kyverno policies in ClusterForge, enabling fine-grained control over which policies are deployed to different cluster sizes.

## Design Philosophy

> **"Each policy module is a separate application that can be independently included or excluded"**

This approach solves the original problem: **How can large clusters use some Kyverno policies but exclude the local-path access mode mutation?**

## Architecture Overview

### 🎯 **Problem Solved**

**Before (Monolithic)**:
```
kyverno-config/
├── dynamic-pvc-creation.yaml       # ✅ All clusters need
└── local-path-mutation.yaml        # ❌ Large clusters don't want
```
**Issue**: Can't cherry-pick policies - it's all or nothing.

**After (Modular)**:
```
kyverno-policies/
├── base/                           # ✅ All clusters
│   └── dynamic-pvc-creation.yaml
├── storage-local-path/             # ✅ Small/medium only  
│   └── access-mode-mutation.yaml
├── security-baseline/              # ✅ Medium/large only
│   └── disallow-privileged.yaml
└── resource-management/            # ✅ Large only
    └── resource-quotas.yaml
```
**Solution**: Each cluster size picks only the policy modules it needs.

### 📊 **Cluster Size Matrix**

| Policy Module | Small | Medium | Large | Purpose |
|---------------|-------|---------|-------|---------|
| `kyverno-policies-base` | ✅ | ✅ | ✅ | Common policies for all |
| `kyverno-policies-storage-local-path` | ✅ | ✅ | ❌ | RWX→RWO conversion |
| `kyverno-policies-security-baseline` | ❌ | ✅ | ✅ | Production security |
| `kyverno-policies-resource-management` | ❌ | ❌ | ✅ | Resource governance |
| `kyverno-policies-compliance-pci` | ❌ | ❌ | ✅ | Regulatory compliance |

## Implementation Details

### 1. **File Structure**

```
cluster-forge/
├── sources/
│   ├── kyverno/                               # Core Kyverno installation
│   ├── kyverno-config/                        # Legacy config (kept for compatibility)
│   └── kyverno-policies/                      # NEW: Modular policies
│       ├── base/
│       │   ├── Chart.yaml
│       │   └── dynamic-pvc-creation.yaml
│       ├── storage-local-path/
│       │   ├── Chart.yaml
│       │   └── access-mode-mutation.yaml
│       ├── security-baseline/
│       │   ├── Chart.yaml
│       │   └── disallow-privileged.yaml
│       └── resource-management/
│           ├── Chart.yaml
│           └── resource-quotas.yaml
└── root/
    ├── values.yaml                           # Includes base policies
    ├── values_small.yaml                     # + storage-local-path
    ├── values_medium.yaml                    # + storage-local-path + security-baseline  
    └── values_large.yaml                     # + security-baseline + resource-management
```

### 2. **Configuration Pattern**

#### Base Configuration (`values.yaml`)
```yaml
enabledApps:
  - kyverno
  - kyverno-config                    # Legacy config
  - kyverno-policies-base             # ✅ NEW: Base policies for all

apps:
  kyverno-policies-base:
    namespace: kyverno
    path: kyverno-policies/base
    source: clusterForge
    syncWave: -2
```

#### Small Clusters (`values_small.yaml`)
```yaml
enabledApps:
  - kyverno-policies-storage-local-path  # ✅ Add local-path policies

apps:
  kyverno-policies-storage-local-path:
    namespace: kyverno
    path: kyverno-policies/storage-local-path
    source: clusterForge
    syncWave: -1
```

#### Medium Clusters (`values_medium.yaml`)  
```yaml
enabledApps:
  - kyverno-policies-storage-local-path  # ✅ Add local-path policies
  - kyverno-policies-security-baseline   # ✅ Add security policies

apps:
  kyverno-policies-storage-local-path:
    # ... same as small
  kyverno-policies-security-baseline:
    namespace: kyverno
    path: kyverno-policies/security-baseline
    source: clusterForge
    syncWave: -1
```

#### Large Clusters (`values_large.yaml`)
```yaml
enabledApps:
  # ❌ NO storage-local-path policies
  - kyverno-policies-security-baseline   # ✅ Add security policies  
  - kyverno-policies-resource-management # ✅ Add resource policies

apps:
  kyverno-policies-security-baseline:
    # ... same as medium
  kyverno-policies-resource-management:
    namespace: kyverno
    path: kyverno-policies/resource-management
    source: clusterForge
    syncWave: -1
```

### 3. **Chart.yaml Template**

Each policy module has its own Chart.yaml:

```yaml
apiVersion: v2
name: kyverno-policies-[module-name]
description: [Module description]
type: application
version: 1.0.0
keywords:
  - kyverno
  - policies
dependencies:
  - name: kyverno
    version: "3.5.1"
annotations:
  cluster-forge.io/target-sizes: "small,medium,large"
  cluster-forge.io/description: "[Purpose and scope]"
```

## Usage Examples

### 📋 **Current State After Refactoring**

```bash
# Small cluster - Gets base + local-path policies
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small

# Medium cluster - Gets base + local-path + security policies
./scripts/bootstrap.sh team.example.com --CLUSTER_SIZE=medium

# Large cluster - Gets base + security + resource policies (NO local-path!)
./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large
```

### 🔮 **Future Extensibility Examples**

#### Adding New Policy Module
1. **Create new module**:
   ```bash
   mkdir sources/kyverno-policies/compliance-gdpr
   # Add Chart.yaml and policy YAML files
   ```

2. **Add to target cluster sizes**:
   ```yaml
   # values_large.yaml
   enabledApps:
     - kyverno-policies-compliance-gdpr  # Only large clusters get GDPR
   ```

#### Environment-Specific Policies
```yaml
# values_prod.yaml (future)
enabledApps:
  - kyverno-policies-audit-enhanced     # Production audit requirements
  - kyverno-policies-network-strict     # Strict network policies
```

#### Custom Policy Combinations
```yaml
# values_gpu.yaml (future)
enabledApps:
  - kyverno-policies-gpu-resource-limits # GPU-specific policies
  - kyverno-policies-ai-workload-security # AI/ML security policies
```

## Benefits of Modular Design

### ✅ **Advantages**

1. **🎯 Precise Control**: Each cluster gets exactly the policies it needs
2. **🔧 Easy Extension**: Adding new policies doesn't affect existing clusters
3. **🧩 Composable**: Mix and match policy modules for different needs
4. **📦 Independent Versioning**: Each module can be versioned separately
5. **🛡️ Zero Interference**: Large clusters guaranteed to never get local-path policies
6. **📝 Clear Documentation**: Each module documents its purpose and target clusters
7. **🔄 Backwards Compatible**: Existing `kyverno-config` still works
8. **🚀 Future-Proof**: Easy to add compliance, security, or custom policy modules

### ❌ **Trade-offs**

1. **📁 More Files**: More directory structure to manage
2. **🔗 Dependencies**: Need to ensure proper sync wave ordering
3. **📋 Configuration**: More enabledApps entries to track

## Design Patterns for New Policies

### 🎨 **Pattern 1: Size-Based Policies**
```
Purpose: Different behavior based on cluster capacity
Examples: Resource limits, replica counts, storage classes
Target: Specific cluster sizes (small, medium, large)
```

### 🛡️ **Pattern 2: Environment-Based Policies**  
```
Purpose: Different security/compliance requirements
Examples: Prod vs dev security, regulatory compliance
Target: Environment types (dev, staging, prod)
```

### 🏗️ **Pattern 3: Workload-Based Policies**
```
Purpose: Specific to application types
Examples: GPU policies, AI/ML policies, database policies  
Target: Clusters running specific workloads
```

### 🏢 **Pattern 4: Compliance-Based Policies**
```
Purpose: Regulatory or organizational requirements
Examples: PCI-DSS, GDPR, SOC2, company-specific
Target: Clusters requiring specific compliance
```

## Migration Guide

### From Monolithic to Modular

1. **Keep existing** `kyverno-config` for compatibility
2. **Create new** policy modules in `kyverno-policies/`
3. **Gradually migrate** policies from config to modules
4. **Test each module** independently
5. **Update cluster configs** to use new modules
6. **Remove old config** once migration is complete

### Adding New Policy Modules

1. **Create module directory**: `sources/kyverno-policies/[module-name]/`
2. **Add Chart.yaml**: Define module metadata and dependencies  
3. **Add policy files**: Actual Kyverno ClusterPolicy resources
4. **Update target configs**: Add to appropriate `values_*.yaml` files
5. **Test deployment**: Verify policies deploy correctly
6. **Document usage**: Update module documentation

## Troubleshooting

### Common Issues

#### Policy Module Not Deployed
```bash
# Check if module is in enabledApps
grep "kyverno-policies-[module]" root/values_*.yaml

# Check ArgoCD application status  
kubectl get application kyverno-policies-[module] -n argocd
```

#### Policy Conflicts
```bash
# Check for duplicate policy names across modules
find sources/kyverno-policies -name "*.yaml" -exec grep "name:" {} \; | sort | uniq -d

# View policy details
kubectl describe clusterpolicy [policy-name]
```

#### Wrong Cluster Has Policy
```bash
# Check which clusters include the policy module
grep -r "kyverno-policies-[module]" root/values_*.yaml

# Verify cluster configuration
kubectl get applications -n argocd | grep kyverno-policies
```

---

**This is the way** - Modular policy design enables precise control, easy extensibility, and guaranteed isolation between cluster sizes! 🔥

## Quick Reference

| Need | Solution |
|------|----------|
| All clusters need policy | Add to `kyverno-policies-base` |
| Only small/medium need policy | Create module, add to `values_small.yaml` and `values_medium.yaml` |
| Only large clusters need policy | Create module, add to `values_large.yaml` only |
| Environment-specific policy | Create module, add to environment-specific values file |
| Future compliance requirement | Create new module, add to target cluster configurations |

The modular design pattern scales from simple size-based policies to complex compliance and workload-specific requirements!