# Cluster-Forge Bootstrap Script

The bootstrap script sets up a complete GitOps environment with ArgoCD, OpenBao (secret management), and Gitea (Git repository) on a Kubernetes cluster. It supports automatic configuration detection and multi-tier cluster deployments.

## Prerequisites

- **Kubernetes cluster** (running and accessible via `kubectl`)
- **Required tools**:
  - `kubectl` - Kubernetes CLI
  - `helm` - Helm package manager
  - `openssl` - SSL/TLS toolkit for password generation
  - `yq` - YAML processor for configuration merging

## Quick Start

```bash
# Auto-detect everything from bloom configmap
./scripts/bootstrap.sh

# Or provide explicit domain
./scripts/bootstrap.sh my-cluster.example.com
```

## Usage

```bash
bootstrap.sh [DOMAIN] [VALUES_FILE]
bootstrap.sh [VALUES_FILE]
bootstrap.sh [-h|--help]
```

### Arguments

- **DOMAIN**: Cluster domain (e.g., `my-cluster.example.com`)
  - If omitted, reads from bloom configmap (`data.domain` key)
- **VALUES_FILE**: Helm values file (`values.yaml`, `values_m.yaml`, `values_l.yaml`) 
  - If omitted, cluster size is auto-detected from bloom configmap (`data.CLUSTER_SIZE` key)

### Options

- `-h, --help`: Show detailed help message

## Cluster Size Configurations

The script supports three deployment tiers that correspond to different infrastructure scales:

### Small (Single-Node)
- **Values file**: `values.yaml`
- **Target**: Workstation/Gaming PC/Single Developer
- **Specs**: 1 node, 16-32 vCPU, 64-128 GB RAM, 1-2 GPUs
- **Storage**: 1-4 TB NVMe, `direct` storage class
- **Use case**: PoC, experimentation, reproducible bug reports

### Medium (Team Environment)  
- **Values files**: `values.yaml` + `values_m.yaml`
- **Target**: Small team, shared environment (5-20 users)
- **Specs**: 1-3 nodes, 32-64 vCPU, 128-256 GB RAM, up to 8 GPUs
- **Storage**: 4-16 TB NVMe, `multinode` storage class
- **Use case**: Concurrent jobs, serving workloads, larger datasets

### Large (Production Scale)
- **Values files**: `values.yaml` + `values_l.yaml` 
- **Target**: Production deployment (10s-100s users)
- **Specs**: 6+ nodes, 32-96 vCPU workers, 256-1024 GB RAM, 8+ GPUs
- **Storage**: 10-100+ TB NVMe, `default` + `mlstorage` classes
- **Use case**: Production workloads, HA everywhere, mixed families

## Configuration Detection

### Bloom ConfigMap

The script can automatically detect both domain and cluster size from a `bloom` configmap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bloom
  namespace: default
data:
  domain: "your-cluster.example.com"      # Required if no domain argument
  CLUSTER_SIZE: "medium"                  # Optional: small, medium, large
```

This configmap is typically created by **cluster-bloom** during cluster provisioning.

### Argument Patterns

The script uses intelligent argument detection:

```bash
# Pattern recognition examples:
./bootstrap.sh                           # Auto-detect both
./bootstrap.sh my-domain.com             # Explicit domain, auto-detect size  
./bootstrap.sh values_l.yaml             # Auto-detect domain, force large
./bootstrap.sh my-domain.com values_m.yaml   # Both explicit
```

## Usage Examples

### Full Auto-Detection
```bash
# Both domain and cluster size from bloom configmap
./bootstrap.sh
```

### Mixed Usage
```bash
# Explicit domain, auto-detect size from bloom configmap
./bootstrap.sh my-cluster.example.com

# Auto-detect domain from bloom configmap, force medium size
./bootstrap.sh values_m.yaml

# Auto-detect domain from bloom configmap, force large size  
./bootstrap.sh values_l.yaml
```

### Explicit Configuration
```bash
# Provide both domain and cluster size explicitly
./bootstrap.sh my-cluster.example.com values_l.yaml
```

## Bootstrap Process

The script performs these steps in sequence:

### 1. Configuration Detection & Validation
- Detects domain from arguments or bloom configmap
- Detects cluster size from arguments or bloom configmap  
- Validates all required files and directories exist
- Merges values files for proper inheritance (base + overrides)

### 2. ArgoCD Bootstrap
- Creates `argocd` namespace
- Deploys ArgoCD with cluster-size appropriate configuration
- Waits for all ArgoCD components (controller, server, repo-server) to be ready
- Configures HA settings based on cluster tier

### 3. OpenBao Bootstrap  
- Creates `cf-openbao` namespace
- Deploys OpenBao secret management system
- Waits for OpenBao pod to be running
- Runs initialization job that:
  - Initializes & configures OpenBao Raft cluster
  - Unseals all pods  
  - Creates root credentials

### 4. Gitea Bootstrap
- Creates `cf-gitea` namespace
- Generates admin credentials
- Creates initial cluster-forge values configmap
- Deploys Gitea Git repository server
- Runs initialization job that:
  - Creates `cluster-org` organization
  - Creates `cluster-forge` as mirror repository
  - Creates `cluster-values` repository with cluster configuration

### 5. Cluster-Forge Deployment
- Deploys main cluster-forge application using merged values
- Creates ArgoCD applications for all enabled components
- Applies cluster-size specific resource allocations and HA settings

## Access Credentials

After successful bootstrap, retrieve access credentials:

### ArgoCD
```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Access URL: https://argocd.<your-domain>
# Username: admin
```

### Gitea  
```bash
# Get admin username
kubectl -n cf-gitea get secret gitea-admin-credentials \
  -o jsonpath="{.data.username}" | base64 -d

# Get admin password  
kubectl -n cf-gitea get secret gitea-admin-credentials \
  -o jsonpath="{.data.password}" | base64 -d

# Access URL: https://gitea.<your-domain>
```

### OpenBao
```bash
# Get root token
kubectl -n cf-openbao get secret openbao-keys \
  -o jsonpath='{.data.root_token}' | base64 -d

# Access URL: https://openbao.<your-domain>
```

## Values File Inheritance

The script implements proper values file inheritance:

- **Small**: Uses only `values.yaml` (base configuration)
- **Medium**: Uses `values.yaml` + `values_m.yaml` (base + team overrides)
- **Large**: Uses `values.yaml` + `values_l.yaml` (base + production overrides)

This ensures that:
- Common configurations are defined once in `values.yaml`
- Tier-specific overrides are minimal and focused
- Helm properly merges configurations with later files taking precedence

## Integration with Cluster-Bloom

This bootstrap script is designed to work seamlessly with **cluster-bloom**:

1. **cluster-bloom** provisions the RKE2 cluster and installs Longhorn (for medium/large)
2. **cluster-bloom** creates the bloom configmap with domain and cluster size
3. **bootstrap script** reads the bloom configmap and deploys cluster-forge
4. **cluster-forge** manages all subsequent application deployments via ArgoCD

## Troubleshooting

### Common Issues

**Domain not found**: 
```bash
# Check if bloom configmap exists
kubectl get configmap bloom -n default

# Check domain value
kubectl get configmap bloom -n default -o jsonpath='{.data.domain}'
```

**Values file not found**:
```bash
# List available values files
ls -1 root/values*.yaml
```

**Timeout during bootstrap**:
```bash
# Check component status
kubectl get pods -n argocd
kubectl get pods -n cf-openbao  
kubectl get pods -n cf-gitea
```

### Debug Mode

For detailed debugging, you can run individual bootstrap functions:
```bash
# Source the script to access individual functions
source scripts/bootstrap.sh

# Run individual components
bootstrapArgocd
bootstrapOpenbao
bootstrapGitea
deployClusterForge
```

## Development Workflow

For development and testing:

1. **Feature branches**: Create feature branch with your changes
2. **Custom values**: Modify appropriate values file for your tier
3. **Test bootstrap**: Run bootstrap script with your configuration
4. **Iterate**: Push changes and let ArgoCD sync automatically

The GitOps workflow ensures that all changes are version controlled and automatically deployed.