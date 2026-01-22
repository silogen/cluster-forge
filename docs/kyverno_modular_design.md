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
└── dynamic-pvc-creation.yaml       # ✅ All clusters need this (from main branch)
```
**Issue**: Adding local-path mutation would affect all clusters, including large clusters with Longhorn.

**After (Modular)**:
```
kyverno-policies/
├── base/                           # ✅ All clusters (matches main branch)
│   └── dynamic-pvc-creation.yaml
└── storage-local-path/             # ✅ Small/medium only  
    └── access-mode-mutation.yaml
```
**Solution**: Each cluster size picks only the policy modules it needs.

### 📊 **Cluster Size Matrix**

| Policy Module | Small | Medium | Large | Purpose |
|---------------|-------|---------|-------|---------|
| **`kyverno-policies-base`** | ✅ | ✅ | ✅ | **Existing policy from main branch** |
| **`kyverno-policies-storage-local-path`** | ✅ | ✅ | ❌ | **NEW: RWX→RWO conversion (excluded from large!)** |

### 🔄 **Compatibility with Main Branch**

| Cluster Type | Policies Deployed | Comparison to Main Branch |
|--------------|-------------------|---------------------------|
| **Medium** (original) | `dynamic-pvc-creation.yaml` + `local-path-access-mode-mutation.yaml` | ✅ **Same as main + local-path compatibility** |
| **Small** (new) | Same as medium but with reduced resources | ✅ **Compatible subset** |
| **Large** (new) | Only `dynamic-pvc-creation.yaml` | ✅ **Exactly matches main branch behavior** |

## Implementation Details

### 1. **File Structure** (Minimal)

```
cluster-forge/
├── sources/
│   ├── kyverno-config/                      # ✅ Preserved from main branch
│   │   └── dynamic-pvc-creation.yaml        # Original policy
│   └── kyverno-policies/                    # ✅ NEW: Modular structure
│       ├── base/
│       │   ├── Chart.yaml
│       │   └── dynamic-pvc-creation.yaml    # Copy of original
│       └── storage-local-path/
│           ├── Chart.yaml
│           └── access-mode-mutation.yaml    # NEW: Only for small/medium
└── root/
    ├── values.yaml                         # ✅ + base policies
    ├── values_small.yaml                   # ✅ + storage-local-path
    ├── values_medium.yaml                  # ✅ + storage-local-path  
    └── values_large.yaml                   # ✅ No additional policies (matches main)
```

### 2. **Configuration Pattern**

#### Base Configuration (`values.yaml`)
```yaml
enabledApps:
  - kyverno                        # ✅ Same as main branch
  - kyverno-config                 # ✅ Same as main branch
  - kyverno-policies-base          # ✅ NEW: Contains dynamic-pvc-creation.yaml
```

#### Small/Medium Clusters (`values_small.yaml`, `values_medium.yaml`)
```yaml
enabledApps:
  # Inherits from base: kyverno + kyverno-config + kyverno-policies-base
  - kyverno-policies-storage-local-path  # ✅ NEW: Adds local-path policies
```

#### Large Clusters (`values_large.yaml`)
```yaml
# ✅ Inherits ONLY base configuration
# No additional policy modules = exactly matches main branch behavior
```

### 3. **Policy Content**

#### Base Policies Module (`kyverno-policies/base/`)
- **Contains**: `dynamic-pvc-creation.yaml` (exact copy from main branch)
- **Purpose**: Preserve existing functionality from main branch
- **Target**: All cluster sizes

#### Storage Local-Path Module (`kyverno-policies/storage-local-path/`)  
- **Contains**: `access-mode-mutation.yaml` (NEW policy for RWX→RWO conversion)
- **Purpose**: Enable local-path compatibility for small/medium clusters
- **Target**: Small and medium clusters only

## Migration Impact

### 📈 **What Changed from Main Branch**

| Cluster Type | Before (Main) | After (Feature Branch) | Impact |
|--------------|---------------|------------------------|--------|
| **Original** | `dynamic-pvc-creation.yaml` | **Medium**: Same + local-path mutation | ✅ **Enhanced compatibility** |
| **N/A** | N/A | **Small**: Same as medium, fewer resources | ✅ **New option** |  
| **N/A** | N/A | **Large**: Exactly same as main | ✅ **Perfect compatibility** |

### 🔄 **Backwards Compatibility**

- **✅ Large clusters**: Identical behavior to main branch
- **✅ Medium clusters**: Main branch behavior + automatic RWX→RWO conversion  
- **✅ Existing policies**: No changes to `dynamic-pvc-creation.yaml`
- **✅ Configuration**: Main branch `kyverno-config` still works

## Usage Examples

### 📋 **Deployment Commands**

```bash
# Small cluster - Main + local-path policies  
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small

# Medium cluster - Main + local-path policies
./scripts/bootstrap.sh team.example.com --CLUSTER_SIZE=medium

# Large cluster - Exactly same as main branch
./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large
```

### 🔍 **Policy Verification**

```bash
# Check deployed policies
kubectl get clusterpolicy

# Small/Medium should show:
# - dynamic-pvc-creation (from base)
# - local-path-access-mode-mutation (from storage-local-path)

# Large should show:
# - dynamic-pvc-creation (from base only)
```

## Future Extensibility

### 🔮 **Adding New Policies (Future)**

The modular structure enables adding new policy modules without affecting existing behavior:

```bash
# Example: Future security policies
mkdir sources/kyverno-policies/security-baseline

# Add only to clusters that need them
# values_large.yaml:
enabledApps:
  - kyverno-policies-security-baseline  # Only large clusters get new security policies
```

### 📋 **Design Principles for New Policies**

1. **✅ Preserve main branch compatibility**: Large clusters should remain unchanged
2. **✅ Add new modules sparingly**: Only when there's a clear cluster-size-specific need
3. **✅ Use existing policies**: Don't duplicate what's already in `kyverno-config`
4. **✅ Document clearly**: Explain why each module exists and which clusters need it

## Benefits

### ✅ **Advantages**

1. **🛡️ Perfect Isolation**: Large clusters guaranteed to match main branch exactly
2. **🎯 Precise Control**: Each cluster gets only the policies it needs
3. **🔄 Backwards Compatible**: No breaking changes from main branch
4. **📦 Future-Proof**: Easy to add new policy modules for specific needs
5. **📝 Clear Intent**: Obviously shows which policies apply to which clusters

### ✨ **Key Guarantees**

- **Large clusters will NEVER get local-path access mode mutation**
- **Medium clusters match main branch + get compatibility enhancement**
- **All cluster sizes get the original `dynamic-pvc-creation.yaml` policy**
- **Future policy additions won't affect existing cluster behavior**

---

**This is the way** - Modular policy design preserves main branch compatibility while enabling cluster-specific enhancements! 🔥

## Quick Reference

| Need | Solution |
|------|----------|
| Keep main branch behavior | Deploy large cluster (inherits only base policies) |
| Add local-path compatibility | Deploy small/medium cluster (gets base + storage-local-path) |
| Add future policies | Create new module, add to specific cluster sizes only |
| Migrate from main branch | All existing behavior preserved in base policies module |