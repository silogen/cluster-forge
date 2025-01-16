# Prometheus-Operator manifests
- Namespace (privileged)
- Stripped-down-CRDs (https://github.com/prometheus-operator/prometheus-operator/releases/tag/v0.79.2)
- Kube-prometheus-stack without default rules (https://github.com/ray-project/kuberay/blob/master/install/prometheus/overrides.yaml)
  - Crean annotations having "helm.sh/hook" from manifests
- 2 monitors (https://github.com/ray-project/kuberay/blob/master/config/prometheus/podMonitor.yaml)

