# Required tools
- cert-manager
- opentelemetry-operator
- prometheus-crds

# This tool consists of
- otel-collector(agent)
- otel-lgtm

# How this otel-collector manifests created
This otel-collector(agent) manifests are created from the modification of openobserve-collector manifests. 
Collector(agent) acting like node-exporter sends telemetries to the endpoint of otel-collector(gateway) which is a component of otel-lgtm stack. 
Current instrumentations are configured to send telemetries to the endpoint of otel-lgtm. 
Users/Developers who want to use auto instrumation need to implement by giving an annotation to their pods.

# Source of otel-lgtm stack
- https://github.com/grafana/docker-otel-lgtm/tree/main

# After deployment
kubectl port-forward -n otel-lgtm-stack service/lgtm-stack 3000:3000 4317:4317 4318:4318

id/password of grafana: admin/admin
