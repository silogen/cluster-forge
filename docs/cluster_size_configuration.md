# Cluster-Forge Size-Based Configuration

This document describes the cluster size-based configuration system for Cluster-Forge, enabling optimal resource allocation based on cluster scale.

## Overview

Cluster-Forge supports three cluster sizes, each with optimized resource allocations:

- **Small**: Developer/single-user setups (1-5 users)
- **Medium**: Team clusters (5-20 users) 
- **Large**: Production/enterprise scale (10s-100s users)

Size configurations use YAML merge semantics where size-specific values override base values.yaml settings.

## File Structure

```
cluster-forge/
├── root/
│   ├── values.yaml              # Base configuration (all applications)
│   ├── values_small.yaml        # Small cluster overrides  
│   ├── values_medium.yaml       # Medium cluster overrides
│   └── values_large.yaml        # Large cluster overrides
└── scripts/
    └── bootstrap.sh             # Main bootstrap script with size support
```

## Cluster Size Specifications

### Small Cluster (`values_small.yaml`)
**Target**: Developer Cluster / Single-User Setup (1-5 users)

**Infrastructure**:
- **Nodes**: 1-2 nodes (single all-in-one or 1 control plane + 1 worker)
- **CPU**: 8-32 vCPU total
- **Memory**: 32-128 GB RAM total  
- **GPU**: 1-4 GPUs (optional)
- **Storage**: 250Gi+ total, local-path StorageClass
- **Networking**: 1 GbE acceptable

**Application Configuration**:
- **ArgoCD**: Single replica, 2 CPU / 4Gi RAM limits
- **MinIO Tenant**: 250Gi storage, single server
- **OpenBao**: Single instance (no HA), 5Gi storage
- **Storage Policies**: Includes `kyverno-policies-storage-local-path` for RWX→RWO conversion
- **Component Replicas**: All single replica deployments

**Use Cases**: Development, testing, proof-of-concept, local workstations

### Medium Cluster (`values_medium.yaml`)
**Target**: Team Cluster (5-20 users)

**Infrastructure**:
- **Nodes**: 3-5 nodes
- **CPU**: 32-64 vCPU per node
- **Memory**: 128-256 GB RAM per node 
- **GPU**: Up to 8 GPUs total (optional)
- **Storage**: 500Gi+ total, local-path or distributed storage
- **Networking**: 10 GbE recommended

**Application Configuration**:
- **ArgoCD**: Single replica, 2 CPU / 4Gi RAM limits
- **MinIO Tenant**: 250Gi storage, single server
- **OpenBao**: Single instance (no HA), 5Gi storage
- **Storage Policies**: Includes `kyverno-policies-storage-local-path` for RWX→RWO conversion
- **Component Replicas**: Balanced single replica configuration

**Use Cases**: Team production workloads, staging environments, CI/CD

### Large Cluster (`values_large.yaml`)  
**Target**: Production-Path / Enterprise Scale (10s-100s users)

**Infrastructure**:
- **Nodes**: 10+ nodes (3-5 dedicated control plane + GPU workers)
- **CPU**: Workers: 32-96 vCPU, Control plane: 8-16 vCPU
- **Memory**: Workers: 256-1024 GB, Control plane: 32-64 GB
- **GPU**: 8+ GPUs baseline, mixed families, heterogeneous
- **Storage**: 1Ti+ total, distributed storage required
- **Networking**: 25 GbE or more recommended

**Application Configuration**:
- **ArgoCD**: Single replica, production-ready resources
- **MinIO Tenant**: 500Gi storage, single server (external HA S3 recommended)
- **OpenBao**: 3 replicas with Raft HA consensus
- **Storage Policies**: No local-path policies (assumes distributed storage)
- **OTEL LGTM Stack**: 50Gi storage per component (Tempo, Loki, Mimir), 10Gi Grafana
- **Component Replicas**: Production-grade, HA where applicable

**Use Cases**: Large-scale production, enterprise deployments, multi-tenant environments

## Usage

### Using the Bootstrap Script

The bootstrap script automatically applies the appropriate size configuration:

```bash
# Default (medium cluster)
./scripts/bootstrap.sh example.com

# Explicitly specify cluster size
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=small
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=medium  
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=large
```

### Configuration Merge Logic

The script combines configurations using YAML merge semantics:
1. **Base**: `values.yaml` (all applications, common defaults)
2. **Size-specific**: `values_[size].yaml` (overrides and size-specific additions)

Later values override earlier ones, allowing size files to contain only the differences (DRY principle).

## Key Configuration Differences

### Storage Strategy

| Size | Storage Approach | RWX Support | Kyverno Policy |
|------|-----------------|-------------|----------------|
| Small | local-path | ❌ (mutated to RWO) | `kyverno-policies-storage-local-path` |
| Medium | local-path or distributed | ❌ (mutated to RWO) | `kyverno-policies-storage-local-path` |
| Large | Distributed storage | ✅ Native RWX | No local-path policy |

### High Availability

| Component | Small | Medium | Large |
|-----------|-------|--------|-------|
| OpenBao | Single instance | Single instance | 3 replicas (Raft HA) |
| ArgoCD | Single replica | Single replica | Single replica |
| Redis | Single instance | Single instance | Single instance |
| Gitea | Single replica | Single replica | Single replica |

### Observability Stack

| Size | Stack | Storage per Component | Notes |
|------|-------|----------------------|-------|
| Small | Basic | Minimal | Resource-constrained |
| Medium | Basic | Moderate | Team-scale monitoring |
| Large | OTEL LGTM | 50Gi (Tempo/Loki/Mimir), 10Gi (Grafana) | Full observability platform |

| Application | Small | Medium | Large | Notes |
|-------------|-------|--------|-------|-------|
| Gitea | Base config | Base config | SQLite, no PostgreSQL/Valkey | Lightweight for all sizes |
| Keycloak | Base config | Base config | 1 replica, optimized resources | CPU: 250-500m, Mem: 512Mi-2Gi |
| Kueue | 1 replica | 1 replica | 1 replica | Workload queue controller |
| KEDA | Base config | Base config | Base config | Event-driven autoscaling |
| KServe | Base config | Base config | Base config | ML model serving |
| Kyverno | Base policies | Base + storage-local-path | Base policies only | Policy engine |
### MinIO Tenant Scaling

| Size | Servers | Storage | Buckets | Notes |
|------|---------|---------|---------|-------|
| Small | 1 | 250Gi | default-bucket, models | Single server, local-path storage |
| Medium | 1 | 250Gi | default-bucket, models | Single server, local-path or distributed |
| Large | 1 | 500Gi | default-bucket, models | Single server, external HA S3 recommended |

### OpenBao Scaling

| Size | Mode | Replicas | Storage | HA Method |
|------|------|----------|---------|-----------|
| Small | Standalone | 1 | 5Gi | None |
| Medium | Standalone | 1 | 5Gi | None |
| Large | HA | 3 | 10Gi (default) | Raft consensus |

## Benefits

1. **Resource Optimization**: Right-sized configurations prevent over/under-provisioning
   - Small: Minimal replicas, basic resources
   - Medium: Balanced configuration for team use
   - Large: Production-grade with HA features

2. **Storage Strategy**: Automatic policy application
   - Small/Medium: Kyverno RWX→RWO mutation for local-path compatibility
   - Large: Native RWX support with distributed storage

3. **Cost Efficiency**: Progressive resource allocation
   - Single replicas for small/medium clusters
   - HA only enabled where needed (large clusters)
   - DRY configuration principle reduces maintenance

4. **Scalability**: Easy path from development to production
   - Consistent application structure across sizes
   - Configuration inheritance reduces duplication
   - Clear upgrade path between sizes

5. **Automation**: Bootstrap script handles all complexity
   - Automatic value file merging
   - Size-appropriate policy application
   - Validation of configurations

## Customization

### Adding Custom Overrides

Modify size-specific values files to adjust resources:

```yaml
# values_large.yaml example
apps:
  openbao:
    valuesObject:
      server:
        ha:
          enabled: true
          replicas: 3  # HA for large clusters
```

### Enabling/Disabling Applications

Control which applications are deployed per size:

```yaml
# values_small.yaml
enabledApps:
  # Inherits base apps, adds storage policy
  - kyverno-policies-storage-local-path
```