# Cluster-Forge

**A Kubernetes platform automation tool that deploys [AMD Enterprise AI Suite](https://enterprise-ai.docs.amd.com/en/latest/) with complete GitOps infrastructure.**

## Overview

**Cluster-Forge** bundles third-party, community, and in-house components into a single, GitOps-managed stack deployable in Kubernetes clusters. It automates the deployment of a complete AI/ML compute platform with all essential services pre-configured and integrated.

Using a bootstrap-first deployment model, Cluster-Forge establishes GitOps infrastructure (ArgoCD, Gitea, OpenBao) before deploying the complete application stack via ArgoCD's app-of-apps pattern.

**Ideal for:**

- **AI/ML Engineers** - Unified platform for model training, serving, and orchestration
- **Platform Engineers** - Infrastructure automation with GitOps patterns
- **DevOps Teams** - Consistent deployment across development, staging, and production
- **Research Teams** - Ephemeral test clusters for experimentation

## 🚀 Quick Start

### Single-Command Deployment
```bash
./scripts/bootstrap.sh <domain> [--CLUSTER_SIZE=small|medium|large]
```

### Size-Aware Deployment Examples
```bash
# Small cluster (1-5 users, development/testing)
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small

# Medium cluster (5-20 users, team production) [DEFAULT]
./scripts/bootstrap.sh team.example.com --CLUSTER_SIZE=medium

# Large cluster (10s-100s users, enterprise scale)
./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large
```

For detailed deployment instructions, see the [Bootstrap Guide](docs/bootstrap_guide.md).

## 📋 Architecture

### Bootstrap-First Deployment

Cluster-Forge uses a three-phase bootstrap process:

**Phase 1: Pre-Cleanup**
- Detects and removes previous installations when applicable
- Ensures clean state for fresh deployments

**Phase 2: GitOps Foundation Bootstrap** (Manual Helm Templates)
1. **ArgoCD** (v8.3.5) - GitOps controller deployed via helm template
2. **OpenBao** (v0.18.2) - Secrets management with initialization job
3. **Gitea** (v12.3.0) - Git server with initialization job

**Phase 3: App-of-Apps Deployment** (ArgoCD-Managed)
- Creates cluster-forge Application pointing to root/ helm chart
- ArgoCD syncs all remaining applications from enabledApps list
- Applications deployed in wave order (-5 to 0) based on dependencies

### Dual Repository GitOps Pattern

**Local Mode (Default)** - Self-contained cluster-native GitOps:
- Uses local Gitea for both cluster-forge and cluster-values repositories
- Zero external dependencies once bootstrapped
- Initialization handled by gitea-init-job

**External Mode** - Traditional GitHub-based GitOps:
- Points to external GitHub repository
- Supports custom branch selection for testing

See [Values Inheritance Pattern](docs/values_inheritance_pattern.md) for detailed architecture.

## 🛠️ Components

### Layer 1: GitOps Foundation
- **ArgoCD 8.3.5** - GitOps continuous deployment controller
- **Gitea 12.3.0** - Self-hosted Git server with SQLite backend
- **OpenBao 0.18.2** - Vault-compatible secrets management
- **External Secrets 0.15.1** - Secrets synchronization operator

### Layer 2: Core Infrastructure

**Networking & Security:**
- **Gateway API v1.3.0** - Kubernetes standard ingress API
- **KGateway v2.1.0-main** - Gateway API implementation with WebSocket support
- **MetalLB v0.15.2** - Bare metal load balancer
- **Cert-Manager v1.18.2** - Automated TLS certificate management
- **Kyverno 3.5.1** - Policy engine with modular policy system

**Storage & Database:**
- **CNPG Operator 0.26.0** - CloudNativePG PostgreSQL operator
- **MinIO Operator 7.1.1** - S3-compatible object storage operator
- **MinIO Tenant 7.1.1** - Tenant deployment with default-bucket and models buckets

### Layer 3: Observability
- **Prometheus Operator CRDs 23.0.0** - Metrics infrastructure
- **OpenTelemetry Operator 0.93.1** - Telemetry collection
- **OTEL-LGTM Stack v1.0.7** - Integrated observability (Loki, Grafana, Tempo, Mimir)

### Layer 4: Identity & Access
- **Keycloak** (keycloak-old chart) - Enterprise IAM with AIRM realm
- **Cluster-Auth 0.5.0** - Kubernetes RBAC integration

### Layer 5: AI/ML Compute Stack

**GPU & Scheduling:**
- **AMD GPU Operator v1.4.1** - GPU device plugin and drivers
- **KubeRay Operator 1.4.2** - Ray distributed computing framework
- **Kueue 0.13.0** - Job queueing with multi-framework support
- **AppWrapper v1.1.2** - Application-level resource scheduling
- **KEDA 2.18.1** - Event-driven autoscaling

**ML Serving & Inference:**
- **KServe v0.16.0** - Model serving platform (Standard deployment mode)

**Workflow & Messaging:**
- **Kaiwo v0.2.0-rc11** - AI workload orchestration
- **RabbitMQ v2.15.0** - Message broker for async processing

### Layer 6: AIRM Application
- **AIRM 0.3.2** - AMD Resource Manager application suite
- **AIM Cluster Model Source** - Cluster resource models for AIRM

## � Configuration

### Cluster Sizing

Three cluster profiles with inheritance-based resource optimization:

**Small Clusters** (1-5 users, dev/test):
- Single replica deployments
- Reduced resource limits (ArgoCD controller: 2 CPU, 4Gi RAM)
- Adds kyverno-policies-storage-local-path for RWX→RWO PVC mutation
- MinIO tenant: 250Gi storage
- Suitable for: Local workstations, development environments

**Medium Clusters** (5-20 users, team production):
- Single replica with moderate resource allocation
- Same storage policies as small (local-path support)
- ArgoCD controller: 2 CPU, 4Gi RAM
- Default configuration for balanced performance
- Suitable for: Small teams, staging environments

**Large Clusters** (10s-100s users, enterprise scale):
- OpenBao HA: 3 replicas with Raft consensus
- No local-path policies (assumes distributed storage)
- MinIO tenant: 500Gi storage
- Production-grade resource allocation
- Suitable for: Production deployments, multi-tenant environments

See [Cluster Size Configuration](docs/cluster_size_configuration.md) for detailed specifications.

### Values Files

Configuration follows a streamlined inheritance pattern:
- **Base**: Common applications with alpha-sorted enabledApps
- **Size-specific**: Only override differences from base (DRY principle)
- **Runtime**: Domain and cluster-specific parameters injected during bootstrap

The bootstrap script uses YAML merge semantics where size-specific values override base values.yaml settings.

## 📚 Documentation

Comprehensive documentation is available in the `/docs` folder:

| Topic | Documentation |
|-------|---------------|
| **Getting Started** | [Bootstrap Guide](docs/bootstrap_guide.md) |
| **Configuration** | [Cluster Size Configuration](docs/cluster_size_configuration.md) |
| **Architecture** | [Values Inheritance Pattern](docs/values_inheritance_pattern.md) |
| **Policy System** | [Kyverno Modular Design](docs/kyverno_modular_design.md) |
| **Storage Policies** | [Kyverno Access Mode Policy](docs/kyverno_access_mode_policy.md) |
| **Operations** | [Backup and Restore](docs/backup_and_restore.md) |

Additional documentation:
- **SBOM**: See `/sbom` folder for software bill of materials generation and validation

## 📝 License

Cluster-Forge is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.

---

<div align="center">
  <p>Give Cluster-Forge a try and let us know how it works for you!</p>
</div>