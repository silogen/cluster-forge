# Cluster-Forge Components Guide

This document provides detailed information about the components available in Cluster-Forge and how to customize them.

## Table of Contents

- [Component Categories](#component-categories)
- [Configuration Basics](#configuration-basics)
- [Core Infrastructure Components](#core-infrastructure-components)
- [Monitoring & Observability Components](#monitoring--observability-components)
- [Database & Storage Components](#database--storage-components)
- [GPU Support Components](#gpu-support-components)
- [ML & Data Services Components](#ml--data-services-components)
- [Security & Management Components](#security--management-components)
- [Creating Component Collections](#creating-component-collections)
- [Customizing Components](#customizing-components)

## Component Categories

Cluster-Forge components are organized into several categories based on their functionality:

1. **Core Infrastructure**: Essential infrastructure services for Kubernetes clusters
2. **Monitoring & Observability**: Tools for monitoring, logging, and observability
3. **Database & Storage**: Database and storage solutions
4. **GPU Support**: Components for GPU integration and management
5. **ML & Data Services**: Machine learning and data processing components
6. **Security & Management**: Security tools and cluster management utilities

## Configuration Basics

Components in Cluster-Forge are configured through the `input/config.yaml` file. Each component entry follows this structure:

```yaml
- name: component-name
  namespace: component-namespace
  manifestpath:
  - path/to/manifests/folder-or-file
  - path/to/additional/manifests
  syncwave: 0  # Optional: controls deployment order (lower numbers deploy first)
  skip-namespace: false  # Optional: skip namespace creation if needed
```

Components can also be grouped into collections:

```yaml
- name: collection-name
  collection:
  - component1
  - component2
  - component3
```

## Core Infrastructure Components

### Longhorn

**Description**: Cloud native distributed storage solution that provides persistent storage for Kubernetes workloads.

**Configuration Example**:
```yaml
- name: longhorn
  namespace: "longhorn"
  manifestpath:
  - longhorn/manifests/sourced
  syncwave: -100  # Deploy early since other components may depend on it
```

### MetalLB

**Description**: Load-balancer implementation for bare metal Kubernetes clusters, enabling services of type LoadBalancer.

**Configuration Example**:
```yaml
- name: metallb
  namespace: metallb-system
  syncwave: -10
  manifestpath:
  - metallb/manifests/sourced
```

### CertManager

**Description**: Certificate management controller for Kubernetes, automating the issuance and renewal of TLS certificates.

**Configuration Example**:
```yaml
- name: certmanager
  namespace: cert-manager
  syncwave: -10
  manifestpath:
  - certmanager/manifests/sourced
```

### External Secrets

**Description**: Kubernetes operator for external secrets management, integrating with external secrets providers.

**Configuration Example**:
```yaml
- name: external-secrets
  namespace: "external-secrets"
  syncwave: -10
  manifestpath:
  - external-secrets/manifests/sourced
```

### Gateway API

**Description**: Next generation Kubernetes Ingress API, providing a more flexible and powerful networking API.

**Configuration Example**:
```yaml
- name: gateway-api
  namespace: default
  syncwave: -200
  manifestpath: 
  - gateway-api/manifests/sourced
```

### KGateway

**Description**: Kubernetes Gateway implementation, providing HTTP/TCP load balancing and routing.

**Configuration Example**:
```yaml
- name: kgateway
  namespace: kgateway-system
  manifestpath:
  - kgateway/manifests/sourced
  - kgateway/manifests/gateway
```

## Monitoring & Observability Components

### Grafana

**Description**: Analytics and interactive visualization web application, providing dashboards for monitoring data.

**Configuration Example**:
```yaml
- name: grafana
  namespace: "grafana"
  syncwave: 1
  manifestpath:
  - grafana/manifests/sourced
```

### Prometheus

**Description**: Monitoring system and time series database, collecting metrics from configured targets.

**Configuration Example**:
```yaml
- name: prometheus
  namespace: "monitoring"
  manifestpath:
  - prometheus/manifests/sourced
```

### Grafana Loki

**Description**: Horizontally-scalable, highly-available log aggregation system.

**Configuration Example**:
```yaml
- name: grafana-loki
  namespace: "grafana-loki"
  syncwave: 1
  manifestpath:
  - grafana-loki/manifests/sourced
```

### Grafana Mimir

**Description**: Highly available, horizontally scalable time series database for Prometheus.

**Configuration Example**:
```yaml
- name: grafana-mimir
  namespace: "grafana-mimir"
  syncwave: 1
  manifestpath:
  - grafana-mimir/manifests/sourced
```

### Promtail

**Description**: Agent that ships the contents of local logs to a Loki instance.

**Configuration Example**:
```yaml
- name: promtail
  namespace: "monitoring"
  manifestpath:
  - promtail/manifests/sourced
```

### OpenObserve

**Description**: Cloud native observability platform for logs, metrics, and traces.

**Configuration Example**:
```yaml
- name: openobserve
  namespace: "openobserve"
  manifestpath:
  - openobserve/manifests/sourced
```

### OpenTelemetry Operator

**Description**: Kubernetes operator for managing OpenTelemetry collectors.

**Configuration Example**:
```yaml
- name: opentelemetry-operator
  namespace: opentelemetry-operator-system
  manifestpath:
  - opentelemetry-operator/manifests/sourced
```

### OTEL-LGTM Stack

**Description**: OpenTelemetry with Loki, Grafana, Tempo, and Mimir for a complete observability stack.

**Configuration Example**:
```yaml
- name: otel-lgtm-stack
  namespace: otel-lgtm-stack
  manifestpath:
  - /otel-lgtm-stack/kube-state-metrics/kube-state-metrics-manifests.yaml
  - /otel-lgtm-stack/node-exporter/node-exporter-manifests.yaml
  - /otel-lgtm-stack/otel-collectors/collector-manifests.yaml
  - /otel-lgtm-stack/otel-lgtm/modified-manifests.yaml
  - /otel-lgtm-stack/dashboards/lgtm-default-dashboards.yaml
  - /otel-lgtm-stack/dashboards/lgtm-gpu-metrics-dashboard.yaml
  - /otel-lgtm-stack/dashboards/lgtm-minio-dashboard.yaml
  syncwave: 1
```

### Kube-Prometheus-Stack

**Description**: End-to-end Kubernetes cluster monitoring with Prometheus, Grafana, and alerting.

**Configuration Example**:
```yaml
- name: kube-prometheus-stack
  namespace: "prometheus-system"
  manifestpath:
  - kube-prometheus-stack/kube-prometheus-stack-manifests.yaml
```

## Database & Storage Components

### MinIO Operator

**Description**: Kubernetes operator for MinIO object storage.

**Configuration Example**:
```yaml
- name: minio-operator
  namespace: "minio-operator"
  syncwave: -1
  manifestpath:
  - minio-operator/manifests/sourced
```

### MinIO Tenant

**Description**: Multi-tenant MinIO deployment managed by the MinIO operator.

**Configuration Example**:
```yaml
- name: minio-tenant
  namespace: minio-tenant-default
  manifestpath:
  - minio-tenant/manifests/sourced
  - minio-tenant/manifests/base
  - minio-tenant/manifests/clustersecretstore
  - minio-tenant/manifests/route
```

### CNPG Operator

**Description**: Cloud Native PostgreSQL operator for managing PostgreSQL clusters.

**Configuration Example**:
```yaml
- name: cnpg-operator
  namespace: cnpg-system
  manifestpath:
  - cnpg/cnpg-operator.yaml
```

### PSMDB Operator

**Description**: Percona Server for MongoDB operator for managing MongoDB clusters.

**Configuration Example**:
```yaml
- name: psmdb-operator
  namespace: "psmdb"
  manifestpath:
  - psmdb-operator/manifests/sourced
```

### Redis

**Description**: In-memory data structure store, used as a database, cache, and message broker.

**Configuration Example**:
```yaml
- name: redis
  namespace: "redis"
  manifestpath:
  - redis/manifests/sourced
```

## GPU Support Components

### AMD GPU Operator

**Description**: Kubernetes operator that manages the lifecycle of AMD Instinct GPUs in a cluster.

**Configuration Example**:
```yaml
- name: amd-gpu-operator
  namespace: "kube-amd-gpu"
  manifestpath:
  - amd-gpu-operator/manifests/sourced
  - amd-gpu-operator/manifests/additions
```

### AMD Device Config

**Description**: Configuration for AMD GPU devices managed by the AMD GPU Operator.

**Configuration Example**:
```yaml
- name: amd-device-config
  namespace: kube-amd-gpu
  skip-namespace: true
  manifestpath:
  - amd-device-config/deviceconfig_example.yaml
```

## ML & Data Services Components

### KubeRay Operator

**Description**: Kubernetes operator for Ray, a unified compute framework for scaling AI and Python applications.

**Configuration Example**:
```yaml
- name: kuberay-operator
  namespace: "default"
  manifestpath:
  - kuberay-operator/manifests/sourced
```

### Kueue

**Description**: Kubernetes-native job queue controller for managing batch jobs.

**Configuration Example**:
```yaml
- name: kueue
  namespace: kueue-system
  manifestpath:
  - kueue/manifests/sourced
```

### AppWrapper

**Description**: Application wrapper for job scheduling and resource management.

**Configuration Example**:
```yaml
- name: appwrapper
  namespace: appwrapper-system
  manifestpath:
    - appwrapper/manifest.yaml
```

### Kaiwo

**Description**: Machine learning workflow management platform.

**Configuration Example**:
```yaml
- name: kaiwo
  namespace: kaiwo
  skip-namespace: true
  syncwave: 10
  manifestpath:
    - kaiwo/install.yaml
```

## Security & Management Components

### Kyverno

**Description**: Kubernetes policy engine for validating, mutating, and generating resources.

**Configuration Example**:
```yaml
- name: kyverno
  namespace: kyverno
  manifestpath:
  - kyverno/manifests/sourced
```

### Trivy

**Description**: Comprehensive security scanner for container images, filesystems, and Git repositories.

**Configuration Example**:
```yaml
- name: trivy
  namespace: trivy-system
  manifestpath:
  - trivy/manifests/sourced
```

### 1Password Secret Store

**Description**: 1Password integration for secrets management in Kubernetes.

**Configuration Example**:
```yaml
- name: 1password-cluster-secret-store
  namespace: external-secrets
  manifestpath:
  - 1password-cluster-secret-store/manifests
```

### K8s Cluster Secret Store

**Description**: Kubernetes native secret store for managing secrets.

**Configuration Example**:
```yaml
- name: k8s-cluster-secret-store
  namespace: cf-es-backend
  manifestpath:
  - k8s-cluster-secret-store/manifests.yaml
```

## Creating Component Collections

Collections allow you to group related components for easier deployment. Here are some examples:

### Hard Requirements Collection

```yaml
- name: hard-requirements
  collection:
  - certmanager
  - external-secrets
  - gateway-api
  - metallb
```

### Routing Collection

```yaml
- name: routing
  collection:
  - hard-requirements
  - kgateway
  - kgateway-crds
```

### MinIO Complete Stack

```yaml
- name: minio-all-together
  collection:
  - minio-operator
  - minio-tenant
```

### Monitoring with Persistent Volumes

```yaml
- name: monitoring-with-pv
  collection:
  - certmanager
  - opentelemetry-operator
  - prometheus-crds
  - otel-lgtm-stack
```

### Kaiwo ML Platform

```yaml
- name: kaiwo-all
  collection:
  - certmanager
  - kuberay-operator
  - kueue
  - appwrapper
  - kaiwo
```

## Customizing Components

Components can be customized by modifying the YAML manifests or providing custom values files.

### Using Custom Values Files

Many components support custom values files for Helm charts:

```yaml
- name: grafana
  namespace: "grafana"
  manifestpath:
  - grafana/manifests/sourced
  values:
    adminPassword: "custom-password"
    persistence:
      enabled: true
      size: 10Gi
```

### Customization Process

1. Run the `smelt` command to generate working files:
   ```bash
   go run . smelt
   ```

2. Edit the generated files in the `working` directory to customize the components.

3. Run the `cast` command to create the deployable stack:
   ```bash
   go run . cast
   ```

For more detailed customization guidance, refer to the README files in the component directories under `input/`.