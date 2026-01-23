# Cluster-Forge

**A helper tool that deploys [AMD Enterprise AI Suite](https://enterprise-ai.docs.amd.com/en/latest/) into Kubernetes cluster.**

## Overview

**Cluster-Forge** is a tool designed to bundle various third-party, community, and in-house components into a single, streamlined stack that can be deployed in Kubernetes clusters. By automating the deployment process, Cluster-Forge simplifies the creation of consistent, ready-to-use clusters.

This tool is ideal for scenarios such as:

- **Ephemeral test clusters** - Create temporary environments quickly
- **CI/CD pipeline clusters** - Ensure consistent testing environments
- **Multiple production clusters** - Manage a fleet of clusters efficiently
- **Reproducible environments** - Ensure consistency across deployments

## 🚀 Quick Start

### Basic Deployment
```bash
./scripts/bootstrap.sh <domain>
```

### Size-Aware Deployment
```bash
# Small cluster (1-5 users, development/testing)
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small

# Medium cluster (5-20 users, team production) [DEFAULT]
./scripts/bootstrap.sh team.example.com --CLUSTER_SIZE=medium

# Large cluster (10s-100s users, enterprise scale)
./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large
```

For detailed deployment instructions, see the [Bootstrap Guide](docs/bootstrap_guide.md).

## 📋 Workflow

Cluster-Forge deploys all necessary components within the cluster using GitOps-controller [ArgoCD](https://argo-cd.readthedocs.io/)
and [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) where Cluster-Forge acts as an app of apps.

### GitOps Architecture

Cluster-Forge supports two deployment modes:
- **External Mode**: Traditional GitOps with GitHub dependency
- **Local Mode**: Self-contained GitOps with local Gitea

See [Values Inheritance Pattern](docs/values_inheritance_pattern.md) for detailed architecture documentation.

## 🛠️ Components

### Layer 1: GitOps Foundation
- **ArgoCD** - GitOps controller for continuous deployment
- **Gitea** - Git repository server for source management  
- **OpenBao** - Vault-compatible secret management system

### Layer 2: Core Infrastructure
**Networking & Security:**
- **Gateway API + KGateway** - Modern ingress and traffic management
- **Cert-Manager** - Automated TLS certificate management
- **MetalLB** - Load balancer for bare metal environments
- **External Secrets Operator** - External secret integration
- **Cilium** - Network security and observability
- **Kyverno** - Policy engine with modular policy system

**Storage & Database:**
- **Longhorn** - Distributed block storage  
- **CNPG Operator** - Cloud-native PostgreSQL management
- **MinIO Operator + Tenant** - S3-compatible object storage

### Layer 3: Observability & Monitoring
- **Prometheus** - Metrics collection and alerting
- **Grafana** - Visualization and dashboarding
- **OpenTelemetry Operator** - Distributed tracing and telemetry
- **OTEL-LGTM Stack** - Unified observability platform (Loki, Grafana, Tempo, Mimir)

### Layer 4: AI/ML Compute Stack
**GPU & Compute:**
- **AMD GPU Operator** - GPU device management and drivers
- **KubeRay Operator** - Ray distributed computing framework
- **KServe** - Kubernetes-native model serving
- **Kueue** - Advanced job queueing system
- **AppWrapper** - Application scheduling and resource management
- **KEDA** - Event-driven autoscaling

**Workflow & Orchestration:**
- **Kaiwo** - Workflow management system
- **RabbitMQ** - Message broker for async processing

### Layer 5: Identity & Access
- **Keycloak** - Enterprise identity and access management
- **Cluster-Auth** - Kubernetes RBAC integration

### Layer 6: AIRM App
- **AIRM API** - Central API layer for AMD Resource Manager
- **AIRM UI** - Frontend interface for resource management
- **AIRM Dispatcher** - Compute workload dispatching agent

## 💾 Storage Classes

Storage classes are provided by default with Longhorn. These can be customized as needed.

| Purpose | StorageClass | Access Mode | Locality |
|---------|--------------|-------------|----------|
| GPU Job | mlstorage | RWO | LOCAL/remote |
| GPU Job | default | RWO | LOCAL/remote |
| Advanced usage | direct | RWO | LOCAL |
| Multi-container | multinode | RWX | ANYWHERE |

## 📄 Configuration

### Cluster Sizing

Cluster-Forge provides three pre-configured cluster profiles:

- **Small**: Minimal resources, local-path storage, RWX→RWO access mode conversion
- **Medium**: Balanced resources, local-path storage, RWX→RWO access mode conversion  
- **Large**: Full enterprise features, Longhorn storage, native RWX support

See [Cluster Size Configuration](docs/cluster_size_configuration.md) for detailed specifications.

### Values Files

Configuration follows a streamlined inheritance pattern:
- **Base**: 52 common applications with alpha-sorted enabledApps
- **Size-specific**: Only override differences from base (DRY principle)
- **Runtime**: Domain and cluster-specific parameters

## 📚 Documentation

Comprehensive documentation is available in the `/docs` folder:

| Topic | Documentation |
|-------|---------------|
| **Getting Started** | [Bootstrap Guide](docs/bootstrap_guide.md) |
| **Configuration** | [Cluster Size Configuration](docs/cluster_size_configuration.md) |
| **Architecture** | [Values Inheritance Pattern](docs/values_inheritance_pattern.md) |
| **Security** | [Kyverno Modular Design](docs/kyverno_modular_design.md) |
| **Policies** | [Kyverno Access Mode Policy](docs/kyverno_access_mode_policy.md) |
| **Secrets** | [Secrets Management Architecture](docs/secrets_management_architecture.md) |
| **Operations** | [Backup and Restore](docs/backup_and_restore.md) |

## 📝 License

Cluster-Forge is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.

---

<div align="center">
  <p>Give Cluster-Forge a try and let us know how it works for you!</p>
</div>