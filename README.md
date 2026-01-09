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

Just run the following bootstrap script to create AMD Enterprise AI Suite in your k8s cluster. More details of the script execution steps are available [here](./scripts/bootstrap.md).

```bash
./scripts/bootstrap.sh <domain>
```

## 📋 Workflow

Cluster-Forge deploys all necessary components within the cluster using GitOps-controller [ArgoCD](https://argo-cd.readthedocs.io/)
and [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) where Cluster-Forge acts as an app of apps.

## 🛠️ Components

### Core Infrastructure
- **Longhorn** - Cloud native distributed storage solution
- **MetalLB** - Load-balancer implementation for bare metal clusters
- **CertManager** - Certificate management controller
- **External Secrets** - Kubernetes operator for external secrets management
- **Gateway API** - Next generation Kubernetes Ingress
- **KGateway** - Kubernetes Gateway implementation

### Monitoring & Observability
- **Grafana** - Metrics visualization and dashboards
- **Prometheus** - Monitoring system and time series database
- **Grafana Loki** - Log aggregation system
- **Grafana Mimir** - Highly available metrics backend
- **Promtail** - Log collector for Loki
- **OpenObserve** - Observability platform
- **OpenTelemetry Operator** - Telemetry collection and management
- **OTEL-LGTM Stack** - OpenTelemetry with Loki, Grafana, Tempo, and Mimir
- **Kube-Prometheus-Stack** - End-to-end Kubernetes cluster monitoring

### Database & Storage
- **MinIO Operator** - Kubernetes operator for MinIO object storage
- **MinIO Tenant** - Multi-tenant MinIO deployment
- **CNPG Operator** - Cloud Native PostgreSQL operator

### GPU Support
- **AMD GPU Operator** - GPU operator for AMD Instinct GPUs
- **AMD Device Config** - Device configuration for AMD GPUs

### ML & Data Services
- **KubeRay Operator** - Kubernetes operator for Ray
- **Kueue** - Job queue controller for Kubernetes
- **AppWrapper** - Application wrapper for job scheduling
- **Kaiwo** - ML workflow management

### Autoscaling
- **KEDA** - Kubernetes Event-driven Autoscaling
- **Kedify OTEL** - OpenTelemetry add-on for KEDA

### Security & Management
- **Kyverno** - Kubernetes policy engine
- **KeyCloak** - SSO and identity & access management

## 💾 Storage Classes

Storage classes are provided by default with Longhorn. These can be customized as needed.

| Purpose | StorageClass | Access Mode | Locality |
|---------|--------------|-------------|----------|
| GPU Job | mlstorage | RWO | LOCAL/remote |
| GPU Job | default | RWO | LOCAL/remote |
| Advanced usage | direct | RWO | LOCAL |
| Multi-container | multinode | RWX | ANYWHERE |

## 📄 Configuration

Cluster-Forge deploys all ArgoCD applications into the cluster using [root helm chart](./root/Chart.yaml).

## 📝 License

Cluster-Forge is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.

---

<div align="center">
  <p>Give Cluster-Forge a try and let us know how it works for you!</p>
</div>
# Test change for workflow validation
