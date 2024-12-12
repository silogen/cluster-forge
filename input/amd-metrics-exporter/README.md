Created with:
helm template metrics-exporter https://github.com/ROCm/device-metrics-exporter/releases/download/v1.0.0/device-metrics-exporter-charts-v1.0.0.tgz > input/amd-metrics-exporter/metrics-exporter.yaml

Tolerations added to ensure it runs on AMD GPU on RKE used in lab. 


```yaml
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
```