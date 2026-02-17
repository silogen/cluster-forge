# Values Inheritance Pattern

## Overview

Cluster-Forge implements a sophisticated dual-repository GitOps deployment pattern that supports both external GitHub deployment and local cluster-native deployment through separate configuration and application repositories.

## Two Deployment Modes

### Local Mode (Default)
```yaml
clusterForge:
  repoUrl: "http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git"
  targetRevision: main

externalValues:
  enabled: true  # Uses multi-source pattern
  repoUrl: "http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git"
  targetRevision: main
```

**Purpose**: Self-contained cluster-native GitOps with local Gitea  
**Use Cases**: Air-gapped environments, autonomous operation, production deployments  
**Network**: Self-contained within cluster network  
**Features**:
- Local Gitea serves both cluster-forge and cluster-values repositories
- Initialization handled by gitea-init-job during bootstrap
- Zero external dependencies once bootstrapped
- Full configuration version control within cluster

### External Mode
```yaml
clusterForge:
  repoUrl: "https://github.com/silogen/cluster-forge.git"
  targetRevision: v1.8.0-rc2

externalValues:
  enabled: false  # Single source from GitHub
```

**Purpose**: Traditional GitOps with external GitHub dependency  
**Use Cases**: Initial deployment, CI/CD pipelines, feature branch testing  
**Network**: Requires external internet access  
**Features**:
- Direct GitHub access for application deployment
- Use `--dev` flag for feature branch development
- Supports custom branch selection for testing

## Size-Specific Inheritance

Cluster-Forge uses YAML merge semantics for cluster size configuration:

```bash
# Bootstrap merges values using yq eval-all
yq eval-all '. as $item ireduce ({}; . * $item)' \
    values.yaml values_medium.yaml
```

### Inheritance Hierarchy
1. **Base**: `values.yaml` (common applications and defaults)
2. **Size Override**: `values_small.yaml`, `values_medium.yaml`, or `values_large.yaml`
3. **External**: `cluster-values/values.yaml` from Gitea (when externalValues.enabled: true)
4. **Runtime**: Domain and cluster-specific parameters injected during bootstrap

### DRY Principle in Size Files

Size files only contain differences from base (Don't Repeat Yourself):

**Base values.yaml**:
- Complete application definitions for all apps
- Alpha-sorted `enabledApps` list
- Common defaults applicable to all sizes

**Size-specific values**:
- Only resource overrides that differ from base
- Size-specific enabledApps additions (e.g., storage policies)
- HA configurations for large clusters

**Example**:
```yaml
# values_small.yaml - only differences
enabledApps:
  - kyverno-policies-storage-local-path  # Added to base list

apps:
  argocd:
    valuesObject:
      controller:
        resources:
          limits:
            cpu: 2000m      # Override from base
            memory: 4Gi
```

| Cluster Size | Apps from Base | Additional Apps | Configuration Overrides |
|--------------|----------------|-----------------|------------------------|
| **Small** | All base apps | +1 (storage policy) | Minimal resources, single replicas |
| **Medium** | All base apps | +1 (storage policy) | Balanced resources, single replicas | 
| **Large** | All base apps | +0 (no additions) | Production resources, OpenBao HA (3 replicas) |

## Bootstrap and GitOps Workflow

### Bootstrap Process

The bootstrap script establishes the GitOps foundation:

**Phase 1: Pre-Cleanup**
- Removes previous installations when applicable

**Phase 2: GitOps Foundation Bootstrap**
1. ArgoCD deployment (helm template)
2. OpenBao deployment and initialization
3. Gitea deployment and initialization
   - Creates cluster-org organization
   - Clones cluster-forge from initial-cf-values ConfigMap
   - Creates cluster-values repository

**Phase 3: App-of-Apps Deployment**
- Creates cluster-forge Application in ArgoCD
- Uses multi-source when externalValues.enabled: true
- ArgoCD manages all remaining applications

### Multi-Source GitOps Pattern

When using local mode (`externalValues.enabled: true`), ArgoCD uses two separate repositories:

**Source 1: Application Source** (`cluster-forge`)
- Helm charts and manifests in `sources/` directory
- Application definitions in `root/` chart
- Component versions and configurations

**Source 2: Configuration Source** (`cluster-values`)  
- Custom `values.yaml` for environment-specific overrides
- Domain and cluster-specific settings
- Independent versioning from application code

This separation enables:
- Different update cadences for infrastructure vs. configuration
- Easy configuration rollback without affecting application versions
- Clear ownership separation

### Value Merge Order

When ArgoCD renders applications with multi-source:

1. **Base values** from `cluster-forge/root/values.yaml`
2. **Size-specific** from `cluster-forge/root/values_<size>.yaml`
3. **External overrides** from `cluster-values/values.yaml`
4. **Runtime parameters** (domain, targetRevision) injected by bootstrap

## Developer Workflow

### Local Configuration Management (Local Mode)

```bash
# Clone local configuration repository from Gitea
git clone http://gitea.cluster.example.com/cluster-org/cluster-values.git
cd cluster-values

# Modify cluster configurations
vim values.yaml
git add values.yaml
git commit -m "Update cluster configuration"
git push

# ArgoCD automatically detects and syncs the changes
```

### Feature Branch Testing (External Mode with --dev)

```bash
# Create feature branch in cluster-forge repository
git checkout -b feature/new-capability
# Make changes to applications or configurations
git commit -am "Add new capability"
git push origin feature/new-capability

# Bootstrap with development mode
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small --dev
# Script prompts for branch selection
# ArgoCD points directly to GitHub feature branch

# Iterate: push changes to feature branch, ArgoCD syncs automatically
```

### Configuration Version Control

Benefits of the dual-repository pattern:
- **Full Git history**: Track all cluster configuration changes
- **Pull request workflow**: Review configuration changes before deployment
- **Automatic deployment**: ArgoCD syncs on Git push
- **Rollback capabilities**: Revert via Git history
- **Separation of concerns**: Infrastructure code vs. environment configuration

## Benefits

1. **🎯 Deployment Flexibility**: Support for both external and local GitOps modes
2. **🔄 Version Control**: Full Git history for all cluster configuration changes  
3. **🛡️ Air-Gap Ready**: Works in secure, isolated environments with local Gitea
4. **👥 Developer Experience**: Local Git access for cluster configuration management
5. **📦 Multi-Source Pattern**: Separate application code from configuration
6. **🔧 Maintainability**: DRY principle eliminates configuration redundancy
7. **🚀 Bootstrap Automation**: Single command establishes complete GitOps infrastructure

This architectural pattern enables clusters to operate with full GitOps benefits while maintaining flexibility for different deployment scenarios from development to air-gapped production environments.