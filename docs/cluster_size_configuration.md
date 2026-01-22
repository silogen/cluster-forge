# ClusterForge Size-Based Configuration

This document describes the cluster size-based configuration system for ClusterForge applications, enabling optimal resource allocation based on cluster scale.

## Overview

ClusterForge now supports three cluster sizes, each with optimized resource allocations for the applications deployed on top of ClusterBloom:

- **Small**: Developer/single-user setups (1-5 users)
- **Medium**: Team clusters (5-20 users) 
- **Large**: Production/enterprise scale (10s-100s users)

## File Structure

```
cluster-forge/
├── root/
│   ├── values.yaml              # Base configuration (all applications enabled)
│   ├── values_small.yaml        # Small cluster overrides  
│   ├── values_medium.yaml       # Medium cluster overrides
│   ├── values_large.yaml        # Large cluster overrides
│   ├── values_dev.yaml          # Development environment overrides
│   └── values_ha.yaml           # High availability overrides
└── scripts/
    └── bootstrap.sh             # Main bootstrap script with size support
```

## Cluster Size Specifications

### Small Cluster (`values_small.yaml`)
**Target**: Developer Cluster / Single-User Setup (1-5 users)

**Infrastructure**:
- **Nodes**: 1 all-in-one or 2 nodes (1×CP + 1×GPU worker)
- **CPU**: 8-32 vCPU total
- **Memory**: 32-128 GB RAM total  
- **GPU**: 1-4 GPUs, no partitioning needed
- **Storage**: 1-4 TB total NVMe, Internal S3: 0.5-2 TB
- **Networking**: 1 GbE acceptable

**Application Configuration**:
- **ArgoCD**: Single replica, minimal resources
- **MinIO**: Single server, 500GB storage
- **OpenBao**: Single instance (no HA)
- **Prometheus**: 7d retention, 10GB storage
- **Grafana**: Single replica, 1GB storage

**Use Cases**: Development, testing, proof-of-concept

### Medium Cluster (`values_medium.yaml`)
**Target**: Team Cluster (5-20 users)

**Infrastructure**:
- **Nodes**: 1-3 nodes (Option A: 1×CP + 1-2 GPU workers, Option B: 3×CP + GPU workers)
- **CPU**: 32-64 vCPU per GPU node
- **Memory**: 128-256 GB RAM per GPU node  
- **GPU**: Up to 8 GPUs total, partitioning optional
- **Storage**: 4-16 TB total NVMe, Internal S3: 2-10 TB
- **Networking**: 10 GbE recommended

**Application Configuration**:
- **ArgoCD**: 2 replicas with HA Redis
- **MinIO**: 3 servers, 6TB total (3×2TB), datasets bucket
- **OpenBao**: 3 replicas with Raft HA
- **Enhanced resources** for team collaboration

**Use Cases**: Production workloads, staging environments

### Large Cluster (`values_large.yaml`)  
**Target**: Production-Path / Scale-Out (10s-100s users)

**Infrastructure**:
- **Nodes**: 3-5 dedicated CP servers + 3-6 GPU nodes (scale to 100s)
- **CPU**: Workers: 32-96 vCPU, CP nodes: 8-16 vCPU
- **Memory**: Workers: 256-1024 GB, CP nodes: 32-64 GB
- **GPU**: 8+ GPUs baseline, mixed families, heterogeneous
- **Storage**: 10-100+ TB NVMe, External HA S3 (recommended)
- **Networking**: 25 GbE or more, optional separate storage network

**Application Configuration**:
- **ArgoCD**: 3 replicas with enhanced PDB
- **MinIO**: External HA S3 recommended
- **OpenBao**: Full HA with enhanced security
- **Full observability stack** with extended retention

**Use Cases**: Large-scale production, enterprise deployments

## Usage

### Using the Bootstrap Script

The bootstrap script automatically selects the appropriate size configuration:

```bash
# Basic usage (auto-detects cluster size)
./scripts/bootstrap.sh example.com

# Explicitly specify cluster size
./scripts/bootstrap.sh example.com --size small
./scripts/bootstrap.sh example.com --size medium  
./scripts/bootstrap.sh example.com --size large

# CI mode (no interactive prompts)
./scripts/bootstrap.sh example.com --size medium --ci
```

### Size Detection Logic

The bootstrap script uses multiple methods to determine cluster size:

1. **Explicit `--size` parameter** (highest priority)
2. **CLUSTER_SIZE from bloom-config ConfigMap** (if available)
3. **Auto-detection based on node count** (fallback to small)

### Configuration Merge Logic

The script combines configurations in this order:
1. **Base**: `values.yaml` (all applications enabled)
2. **Size-specific**: `values_[size].yaml` (resource overrides)
3. **Environment-specific**: `values_dev.yaml` or `values_ha.yaml` (if specified)

## Application-Specific Configurations

### ArgoCD Scaling

| Size | Controller Replicas | Repo Server Replicas | Redis HA | Resources |
|------|--------------------|--------------------|----------|-----------|
| Small | 1 | 1 | Disabled | Minimal |
| Medium | 2 | 2 | Enabled | Standard |
| Large | 3 | 3 | Enhanced | High + PDB |

### MinIO Tenant Scaling

| Size | Servers | Storage per Server | Total Storage | Buckets |
|------|---------|-------------------|---------------|---------|
| Small | 1 | 500Gi | 500GB | Basic (default, models) |
| Medium | 3 | 2Ti | 6TB | + datasets |
| Large | External | - | 10-100+ TB | Full enterprise |

### OpenBao Scaling

| Size | Mode | Replicas | Storage | HA Method |
|------|------|----------|---------|-----------|
| Small | Standalone | 1 | 1Gi | None |
| Medium | HA | 3 | Standard | Raft |
| Large | HA | 3+ | Enhanced | Raft + external |

## Advanced Configuration

### Combining Size with Environment

```bash
# Small development cluster
./scripts/bootstrap.sh dev.example.com --size small

# Large production cluster with HA
./scripts/bootstrap.sh prod.example.com --size large
```

### Custom Overrides

You can add additional override files:

```bash
# Custom GPU configuration for large cluster
./scripts/bootstrap.sh gpu.example.com --size large -f custom-gpu-values.yaml
```

### Environment Variables

The script supports environment variables:
- `CLUSTER_SIZE`: Override detected size
- `DOMAIN`: Set domain if not provided as argument
- `CI_MODE`: Enable CI mode (equivalent to `--ci`)

## Validation

The bootstrap script validates:
- **Node count** against cluster size requirements
- **Resource availability** for the selected size
- **Application compatibility** with cluster capabilities

## Migration Between Sizes

To change cluster size:

1. **Update the size parameter**: Re-run bootstrap with new `--size`
2. **Resource validation**: Ensure cluster meets new requirements  
3. **Application scaling**: ArgoCD will handle application updates
4. **Storage considerations**: May require storage expansion for larger sizes

## Benefits

1. **Resource Optimization**: Right-sized configurations prevent over/under-provisioning
2. **Cost Efficiency**: Small clusters use minimal resources
3. **Scalability**: Easy to migrate between sizes as needs grow
4. **Consistency**: Standardized configurations across deployments
5. **Automation**: Bootstrap script handles complexity

## Troubleshooting

### Size Detection Issues
```bash
# Check current size detection
kubectl get configmap bloom-config -n default -o yaml

# Force size override
./scripts/bootstrap.sh example.com --size medium
```

### Resource Constraints
```bash
# Validate node resources
kubectl describe nodes

# Check for resource contention
kubectl top nodes
kubectl top pods --all-namespaces
```

### Application Scaling Issues
```bash
# Check ArgoCD application status
kubectl get applications -n argocd

# View specific application details  
kubectl describe application <app-name> -n argocd
```

---

**This is the way** - A scalable configuration system that adapts ClusterForge applications to cluster capacity, ensuring optimal performance across all deployment sizes!