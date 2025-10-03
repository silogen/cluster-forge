# Required tools
- cert-manager
- opentelemetry-operator
- prometheus-crds
- node-exporter
- kube-state-metrics

# This tool consists of
- otel-collectors for metrics and logs
- otel-lgtm

# How this otel-collector manifests created
There are two otel-collectors for lgtm-stack, otel-collector-metrics and otel-collector-logs


Node level and cluster level metrics are collected and exposed by "node-exporter" 
and "kube-state-metrics", respectively. Otel-collector-metrics pod is a dedicated collector 
controlled by deployment to scrape metrics. So "scrape_configs" and 
giving annotation like "prometheus.io/scrape: 'true'", prometheus.io/path: '/metrics'  to pods
is the key to control what metrics should be scraped.
ref: https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/configuration/helm-chart-config/otel-collector/

Node level and cluster level logs are collected by "otel-collector-logs" pods which are 
controlled by daemonset to collect logs.

This otel-collector-logs manifest is created from the modification of openobserve-collector manifests. 

Current instrumentations are configured to send telemetries to the endpoint of otel-lgtm. 
Users/Developers who want to use auto instrumation need to implement by giving an annotation to their pods.

# Source of otel-lgtm stack
- https://github.com/grafana/docker-otel-lgtm/tree/main

# How to access the grafana of lgtm
kubectl port-forward -n otel-lgtm-stack service/lgtm-stack 3000:3000 4317:4317 4318:4318

id/password of grafana: admin/admin

# Simple use case(Log)
1. Login
2. Go to explore
3. Select "Loki" datasource
4. Use label filters

# Disclaimer
[docker-otel-lgtm](https://github.com/grafana/docker-otel-lgtm/tree/main/docker) is added Cluster-Forge for development, demo, and testing. The only changed part is as follows at "otelcol-config.yaml" to make a custom image. We don't manage/develop this.
```
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 128 <-- added
```


