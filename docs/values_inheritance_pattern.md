# Values Inheritance Pattern

## Overview

ClusterForge implements a sophisticated GitOps deployment pattern that supports both external GitHub deployment and local cluster-native deployment through dual values files and repository configurations.

## Two Deployment Modes

### External Mode (`values.yaml`)
```yaml
clusterForge:
  repoUrl: "https://github.com/silogen/cluster-forge.git"
  targetRevision: v1.7.1
  valuesFile: values.yaml

externalValues:
  enabled: false  # Uses single external source
```

**Purpose**: Traditional GitOps with external GitHub dependency
**Use Cases**: Initial deployment, CI/CD pipelines, production releases
**Network**: Requires external internet access

### Local Mode (`values_cf.yaml`)
```yaml
clusterForge:
  repoUrl: "http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git"
  targetRevision: main

externalValues:
  enabled: true  # Uses local multi-source
  repoUrl: "http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git"
  targetRevision: main
  path: values_cf.yaml
```

**Purpose**: Self-contained GitOps with local Gitea and separate configuration repository
**Use Cases**: Air-gapped environments, developer clusters, autonomous operation
**Network**: Self-contained within cluster network

## Size-Specific Inheritance

ClusterForge uses Helm's multi-values file support for cluster size configuration:

```bash
helm template -f values.yaml -f values_medium.yaml
```

### Inheritance Hierarchy
1. **Base**: `values.yaml` or `values_cf.yaml` (52 common applications)
2. **Size Override**: `values_small.yaml`, `values_medium.yaml`, or `values_large.yaml`
3. **Runtime**: Domain and cluster-specific parameters

### Size File Structure
- **Base files**: Complete application definitions and 52 enabledApps
- **Size files**: Only contain differences from base (DRY principle)
- **Large clusters**: No size file needed (inherit everything from base)

| Cluster Size | Apps from Base | Additional Apps | Total Apps |
|--------------|----------------|-----------------|-----------|
| **Small** | 52 (inherited) | +1 (storage policy) | **53 apps** |
| **Medium** | 52 (inherited) | +1 (storage policy) | **53 apps** |  
| **Large** | 52 (inherited) | +0 (no additions) | **52 apps** |

## Repository Transition Pattern

### Bootstrap Workflow
1. **External Bootstrap**: Deploy from GitHub for initial setup
2. **Local Transition**: Switch to local Gitea for autonomous operation
3. **Developer Access**: Local Git workflows for cluster configuration
4. **Upstream Sync**: Periodic synchronization with main project

### Multi-Source GitOps
When using `values_cf.yaml`, ArgoCD uses two separate repositories:
- **Application Source**: `cluster-org/cluster-forge` (Helm charts and manifests)
- **Configuration Source**: `cluster-org/cluster-values` (values.yaml customizations)

This separation enables independent versioning of infrastructure vs. settings.

## Developer Workflow

### Local Configuration Management
```bash
# Clone local configuration repository
git clone http://gitea.cluster.example.com/cluster-org/cluster-values.git
cd cluster-values

# Modify cluster configurations
vim values_cf.yaml
git add values_cf.yaml
git commit -m "Update cluster configuration"
git push

# ArgoCD automatically deploys the changes
```

### Configuration Version Control
- All cluster configuration changes tracked in Git history
- Pull request workflow for configuration reviews
- Automatic deployment through ArgoCD sync
- Rollback capabilities through Git revert

## Benefits

1. **🎯 Deployment Flexibility**: External dependency → local autonomy transition
2. **🔄 Version Control**: Full Git history for all cluster configuration changes  
3. **🛡️ Air-Gap Ready**: Works in secure, isolated environments
4. **👥 Developer Experience**: Local Git access for cluster configuration
5. **📦 Upstream Sync**: Can receive updates from main project
6. **🔧 Maintainability**: DRY principle eliminates configuration redundancy

This architectural pattern enables clusters to evolve from external dependency to local autonomy while maintaining all benefits of declarative configuration management.