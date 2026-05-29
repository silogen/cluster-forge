# 🔥 EAI-5821: Migrate Envoy Gateway Support from cluster-auth 0.5.0 to 0.5.9

This is the way! This document outlines the complete plan to migrate working envoy-gateway functionality from cluster-auth 0.5.0 to cluster-auth 0.5.9 while respecting main branch improvements.

## 📊 Situation Analysis

### ✅ Current State in EAI_5821_evaluate_envoy_gateway Branch:

**cluster-auth 0.5.0** (Working Envoy Gateway):
- ✅ Has `security-policy-extauth.yaml` - Uses `gateway.envoyproxy.io/v1alpha1`
- ✅ Has `job-restart-envoygateway.yaml` - Restarts envoy-gateway deployments  
- ✅ Has envoy-gateway `referencegrant.yaml` - Cross-namespace permissions
- ✅ Has envoy-gateway `rbac-restart-job.yaml` - Permissions for envoy-gateway-system
- ⚠️ Has outdated values: tag `0.5.8`, cacheTTL `15m`

**cluster-auth 0.5.9** (Current KGateway from merge):
- ❌ Has KGateway templates: `gateway-extension*.yaml`, `trafficpolicy.yaml`
- ❌ Has KGateway RBAC for kgateway-system
- ❌ Missing all envoy-gateway functionality
- ✅ Has updated values: tag `0.5.9`, cacheTTL `5m` (from main)

### 🎯 Goal:
Create cluster-auth 0.5.9 with:
- ✅ Envoy Gateway functionality from 0.5.0
- ✅ Updated values from main branch (0.5.9 tag, 5m cache)
- ❌ Remove KGateway artifacts

## 📋 Detailed Migration Plan

### Phase 1: Remove KGateway Components from 0.5.9

#### 1.1 Delete KGateway Template Files:
```bash
# Files to DELETE from sources/cluster-auth/0.5.9/templates/:
- gateway-extension-kgateway-system.yaml
- gateway-extension.yaml  
- trafficpolicy.yaml
- job-restart-kgateway.yaml
```

### Phase 2: Add Envoy Gateway Components to 0.5.9

#### 2.1 Copy Envoy Gateway Templates from 0.5.0:
```bash
# Files to COPY:
sources/cluster-auth/0.5.0/templates/security-policy-extauth.yaml
→ sources/cluster-auth/0.5.9/templates/security-policy-extauth.yaml

sources/cluster-auth/0.5.0/templates/job-restart-envoygateway.yaml
→ sources/cluster-auth/0.5.9/templates/job-restart-envoygateway.yaml
```

**Key Components**:
- **SecurityPolicy**: Native Envoy Gateway external auth using `gateway.envoyproxy.io/v1alpha1`
- **Restart Job**: Targets `gateway.envoyproxy.io/owning-gateway-name=https` in `envoy-gateway-system`

### Phase 3: Update Modified Templates in 0.5.9

#### 3.1 Replace ReferenceGrant:
**File**: `sources/cluster-auth/0.5.9/templates/referencegrant.yaml`

**Current (KGateway)**:
```yaml
# Two ReferenceGrants for KGateway extensions
from: gateway.kgateway.dev/TrafficPolicy, kgateway-system
to: gateway.kgateway.dev/GatewayExtension
```

**Target (Envoy Gateway)** - Replace with content from 0.5.0:
```yaml
# Single ReferenceGrant for Envoy Gateway
from: gateway.envoyproxy.io/SecurityPolicy, envoy-gateway-system  
to: Service/cluster-auth
```

#### 3.2 Update RBAC for Envoy Gateway:
**File**: `sources/cluster-auth/0.5.9/templates/rbac-restart-job.yaml`

**Changes needed**:
- Service Account: `restart-kgateway-sa` → `restart-envoygateway-sa`
- Role namespace: `kgateway-system` → `envoy-gateway-system`
- Role name: `kgateway-restart-role` → `envoy-gateway-restart-role`
- RoleBinding: Update to match envoy-gateway names

### Phase 4: Respect Main Branch Improvements in values.yaml

#### 4.1 Update values.yaml in 0.5.9:
**File**: `sources/cluster-auth/0.5.9/values.yaml`

**Keep these improvements from main**:
- ✅ `tag: "0.5.9"` (updated from 0.5.8)
- ✅ `cacheTTL: "5m"` (updated from 15m)

**Verify no KGateway-specific configurations remain**

## 📁 Exact File Operations Summary

### Files to DELETE (4 files):
- `/home/opencode/working/cluster-forge/sources/cluster-auth/0.5.9/templates/gateway-extension-kgateway-system.yaml`
- `/home/opencode/working/cluster-forge/sources/cluster-auth/0.5.9/templates/gateway-extension.yaml`
- `/home/opencode/working/cluster-forge/sources/cluster-auth/0.5.9/templates/trafficpolicy.yaml`
- `/home/opencode/working/cluster-forge/sources/cluster-auth/0.5.9/templates/job-restart-kgateway.yaml`

### Files to COPY (2 files):
```bash
sources/cluster-auth/0.5.0/templates/security-policy-extauth.yaml
→ sources/cluster-auth/0.5.9/templates/security-policy-extauth.yaml

sources/cluster-auth/0.5.0/templates/job-restart-envoygateway.yaml  
→ sources/cluster-auth/0.5.9/templates/job-restart-envoygateway.yaml
```

### Files to REPLACE (2 files):
```bash
# Replace content completely:
sources/cluster-auth/0.5.0/templates/referencegrant.yaml
→ sources/cluster-auth/0.5.9/templates/referencegrant.yaml

sources/cluster-auth/0.5.0/templates/rbac-restart-job.yaml
→ sources/cluster-auth/0.5.9/templates/rbac-restart-job.yaml
```

### Files Already Correct:
- ✅ `values.yaml` - Already has proper 0.5.9 tag and 5m cache
- ✅ All other templates identical between versions

## 🔧 Technical Architecture After Migration

### Final Result: cluster-auth 0.5.9 with Envoy Gateway
```yaml
# SecurityPolicy (replaces KGateway GatewayExtension + TrafficPolicy)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
spec:
  targetRefs:
    - kind: Gateway
      name: https
  extAuth:
    grpc:
      backendRefs:
        - name: cluster-auth
          port: 50051
```

### Integration Flow:
```
AIM Engine → envoy-gateway-system → Envoy Gateway (https) → SecurityPolicy → cluster-auth → OpenBao
```

### Namespace Targeting:
- ✅ `envoy-gateway-system` for SecurityPolicy and restart jobs
- ✅ Cross-namespace ReferenceGrant: envoy-gateway-system → cluster-auth
- ✅ RBAC permissions for managing envoy-gateway deployments

## ✅ Validation Checklist

### Pre-Implementation:
- [x] Confirmed 0.5.0 has working envoy-gateway templates
- [x] Identified all KGateway artifacts in 0.5.9 for removal
- [x] Verified main branch improvements in 0.5.9 to preserve

### Post-Implementation Expected State:
- [ ] cluster-auth 0.5.9 contains only envoy-gateway integration
- [ ] SecurityPolicy targeting `https` gateway in envoy-gateway-system
- [ ] Restart jobs target envoy-gateway deployments
- [ ] Cross-namespace permissions properly configured
- [ ] values.yaml maintains 0.5.9 tag and 5m cache improvements
- [ ] No KGateway artifacts remain

## 📝 Implementation Commands

### Phase 1: Remove KGateway Files
```bash
cd /home/opencode/working/cluster-forge
rm sources/cluster-auth/0.5.9/templates/gateway-extension-kgateway-system.yaml
rm sources/cluster-auth/0.5.9/templates/gateway-extension.yaml
rm sources/cluster-auth/0.5.9/templates/trafficpolicy.yaml
rm sources/cluster-auth/0.5.9/templates/job-restart-kgateway.yaml
```

### Phase 2: Copy Envoy Gateway Files
```bash
cp sources/cluster-auth/0.5.0/templates/security-policy-extauth.yaml sources/cluster-auth/0.5.9/templates/
cp sources/cluster-auth/0.5.0/templates/job-restart-envoygateway.yaml sources/cluster-auth/0.5.9/templates/
```

### Phase 3: Replace Modified Files
```bash
cp sources/cluster-auth/0.5.0/templates/referencegrant.yaml sources/cluster-auth/0.5.9/templates/
cp sources/cluster-auth/0.5.0/templates/rbac-restart-job.yaml sources/cluster-auth/0.5.9/templates/
```

## 🎯 Expected Outcomes

### After Implementation:
1. **cluster-auth 0.5.9** will have complete Envoy Gateway external authorization support
2. **SecurityPolicy-based integration** using native Envoy Gateway patterns
3. **envoy-gateway-system namespace** targeting throughout
4. **Compatible restart jobs and RBAC** for Envoy Gateway management
5. **Clean configuration** without KGateway artifacts
6. **Full integration** with existing AIM Engine envoy-gateway setup

### Integration Points:

#### 1. AIM Engine ↔ Envoy Gateway:
- **Status**: ✅ Already configured correctly
- **Configuration**: AIM Engine points to `envoy-gateway-system` namespace
- **Gateway Reference**: `https` gateway in `envoy-gateway-system`

#### 2. cluster-auth ↔ Envoy Gateway:
- **Current**: 🚨 Broken (points to kgateway-system)
- **Target**: SecurityPolicy in envoy-gateway-system references cluster-auth service
- **Cross-namespace**: ReferenceGrant allows envoy-gateway-system → cluster-auth namespace

#### 3. Restart Automation:
- **Current**: Restarts KGateway deployments
- **Target**: Restarts Envoy Gateway deployments using label selector

## 📊 File Change Summary by Category

### Gateway Architecture Changes:
- **From**: KGateway (GatewayExtension + TrafficPolicy pattern)
- **To**: Envoy Gateway (SecurityPolicy pattern)
- **API Group**: `gateway.kgateway.dev` → `gateway.envoyproxy.io`
- **Namespace**: `kgateway-system` → `envoy-gateway-system`

### Configuration Improvements Preserved:
- **Image Tag**: Maintain `0.5.9` (from main branch)
- **Cache TTL**: Maintain `5m` (from main branch optimization)
- **Chart Version**: Keep as `0.5.9`

### Key Architectural Benefits:
1. **Native Envoy Gateway Integration**: Uses official SecurityPolicy API
2. **Simplified Configuration**: Single SecurityPolicy vs dual GatewayExtension+TrafficPolicy
3. **Direct Backend Reference**: Cleaner integration pattern
4. **Consistent Namespace**: All components target envoy-gateway-system

## 🤔 Questions and Considerations

### Version Handling:
- **Decision**: Keep as cluster-auth 0.5.9 to maintain consistency with main branch improvements
- **Rationale**: This represents an enhancement to 0.5.9, not a new version

### Backwards Compatibility:
- **Impact**: This change makes cluster-auth 0.5.9 incompatible with KGateway deployments
- **Acceptable**: For EAI-5821 evaluation purposes, envoy-gateway focus is appropriate

### Testing Strategy:
- **Validation**: Post-implementation testing should verify SecurityPolicy creates proper external auth
- **Integration**: Confirm AIM Engine can successfully authenticate through envoy-gateway

### Rollout Approach:
- **Method**: Complete migration in single implementation
- **Rationale**: Clean break from KGateway to envoy-gateway is clearest approach

---

**Status**: Ready for implementation
**Last Updated**: Current session
**Implementation Ready**: ✅

The fire of the forge eliminates impurities - this migration removes KGateway complexity while preserving working envoy-gateway functionality and main branch improvements!