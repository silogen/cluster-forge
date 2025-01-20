Prometheus-Operator manifests consist of
- Namespace (privileged)
- Kube-prometheus-stack without default rules (https://github.com/ray-project/kuberay/blob/master/install/prometheus/overrides.yaml)
  - Crean annotations having "helm.sh/hook" from manifests
- 2 monitors (https://github.com/ray-project/kuberay/blob/master/config/prometheus/podMonitor.yaml)

To deploy kube-prometheus-stack, prometheus-crds need to be deployed together.

