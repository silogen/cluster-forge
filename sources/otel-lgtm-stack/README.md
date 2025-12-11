# OpenTelemetry LGTM Stack

A comprehensive observability stack providing Logs, Grafana, Tempo, and Mimir (LGTM) for Kubernetes clusters using OpenTelemetry.

## Required Tools

- cert-manager
- opentelemetry-operator  
- prometheus-crds
- node-exporter
- kube-state-metrics

## This Tool Consists Of

- **OpenTelemetry Collectors** - Metrics, logs, and events collection
- **LGTM Stack** - Integrated Loki, Grafana, Tempo, Mimir observability platform
- **Auto-instrumentation** - Support for .NET, Go, Java, Node.js, Python applications
- **Kubernetes Monitoring** - Node and cluster-level metrics collection

## How This OpenTelemetry Collector Manifests Created

### Metrics Collection
Node-level and cluster-level metrics are collected by dedicated collectors:
- **Node Exporter** and **Kube State Metrics** expose metrics endpoints
- **otel-collector-metrics** pods (deployment) scrape configured endpoints  
- Control collection via `scrape_configs` and pod annotations:
  - `prometheus.io/scrape: 'true'`
  - `prometheus.io/path: '/metrics'`

Reference: [Grafana Kubernetes Monitoring Guide](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/configuration/helm-chart-config/otel-collector/)

### Logs Collection
- **otel-collector-logs** pods (daemonset) collect container logs cluster-wide
- **otel-collector-logs-events** (deployment) collects Kubernetes events
- Based on modified [openobserve-collector](https://github.com/openobserve/openobserve-collector) manifests

### Auto-Instrumentation
Pre-configured instrumentation resources for automatic telemetry injection. Applications can enable auto-instrumentation by adding pod annotations.

## Source of OTEL-LGTM Stack

- **Silogen Fork**: [silogen/docker-otel-lgtm](https://github.com/silogen/docker-otel-lgtm)
- **Upstream**: [grafana/docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm/tree/main)
- **Version**: v1.0.7
- **Image**: `ghcr.io/silogen/docker-otel-lgtm:v1.0.7`

## How to Access Grafana

```bash
kubectl port-forward -n otel-lgtm-stack service/lgtm-stack 3000:3000 4317:4317 4318:4318
```

**Default Credentials**: admin/admin

**Access URLs**:
- Grafana: http://localhost:3000
- OTLP gRPC: http://localhost:4317  
- OTLP HTTP: http://localhost:4318

### Simple Log Exploration
1. Login to Grafana
2. Navigate to **Explore**
3. Select **Loki** datasource
4. Use label filters to query logs

## Architecture & Management

**LGTM Stack Image**: We maintain a [silogen/docker-otel-lgtm](https://github.com/silogen/docker-otel-lgtm) fork specifically for managing and updating the LGTM container image. This fork is based on the upstream [grafana/docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm) project.

**Kubernetes Resources**: All Kubernetes manifests (OpenTelemetry Collectors, RBAC, instrumentation, etc.) are managed through our custom Helm chart stored in Cluster-Forge, **not** from the upstream docker-otel-lgtm repository.

**Custom LGTM Image Modifications**: Our fork includes the following changes in `otelcol-config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 128 # <-- added
```

**Scope of Management**:
- 🔧 **Image Management**: Silogen maintains the docker-otel-lgtm fork for LGTM container updates
- 📦 **Resource Management**: All OpenTelemetry collectors, RBAC, and Kubernetes resources are managed via this Cluster-Forge Helm chart
- 🎯 **Integration**: The chart integrates the custom LGTM image with our OpenTelemetry collector architecture