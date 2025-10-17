# Software Bill of Materials (SBOM) - Complete

## All Components

| No | Name | Version | Project |
|----|------|---------|---------|
| 1 | argocd | [8.3.5](https://argoproj.github.io/argo-helm) | https://argoproj.github.io/ |
| 2 | cert-manager | [1.18.2](oci://quay.io/jetstack/charts/cert-manager) | https://cert-manager.io/ |
| 3 | openbao | [0.18.2](https://openbao.github.io/openbao-helm) | https://openbao.org/ |
| 4 | external-secrets | [0.15.1](https://charts.external-secrets.io) | https://external-secrets.io/main/ |
| 5 | gitea | [12.3.0](https://dl.gitea.com/charts/) | https://github.com/go-gitea/gitea |
| 6 | gateway-api | [1.3.0](https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml) | https://gateway-api.sigs.k8s.io/ |
| 7 | metallb | [0.15.2](https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml) | https://github.com/metallb/metallb/ |
| 8 | kgateway-crds | [2.1.0-main](oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds) | https://kgateway.dev/ |
| 9 | kgateway | [2.1.0-main](oci://cr.kgateway.dev/kgateway-dev/charts/kgateway) | https://kgateway.dev/ |
| 10 | prometheus-crds | [23.0.0](https://prometheus-community.github.io/helm-charts) | https://github.com/prometheus-community/ |
| 11 | opentelemetry-operator | [0.93.1](https://open-telemetry.github.io/opentelemetry-helm-charts) | https://opentelemetry.io/ |
| 12 | otel-lgtm-stack | [otel-lgtm-stack](https://github.com/silogen/docker-otel-lgtm) | https://github.com/grafana/docker-otel-lgtm |
| 13 | cnpg-operator | [0.26.0](https://cloudnative-pg.github.io/charts) | https://cloudnative-pg.github.io/ |
| 14 | keycloak | [keycloak-old](https://codecentric.github.io/helm-charts) | https://github.com/keycloak/keycloak |
| 15 | kyverno | [3.5.1](https://kyverno.github.io/kyverno/) | https://github.com/kyverno/kyverno |
| 16 | amd-gpu-operator | [1.4.0](https://rocm.github.io/gpu-operator) | https://github.com/ROCm/ROCm |
| 17 | kuberay-operator | [1.4.2](https://ray-project.github.io/kuberay-helm/) | https://github.com/ROCm/ROCm |
| 18 | rabbitmq | [2.15.0](https://github.com/rabbitmq/cluster-operator/releases/download/v2.15.0/cluster-operator.yml) | https://github.com/rabbitmq/cluster-operator/ |
| 19 | kueue | [0.13.0](oci://registry.k8s.io/kueue/charts/kueue) | https://kueue.sigs.k8s.io/ |
| 20 | appwrapper | [1.1.2](https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml) | https://github.com/project-codeflare/appwrapper |
| 21 | minio-operator | [7.1.1](https://operator.min.io) | https://github.com/minio/operator |
| 22 | minio-tenant | [7.1.1](https://operator.min.io) | https://github.com/minio/operator |
| 23 | kaiwo | [0.1.7](https://github.com/silogen/kaiwo/releases/download/v0.1.7/install.yaml) | https://github.com/silogen/kaiwo/ |
| 24 | airm | [airm](https://github.com/silogen/cluster-forge/tree/main/sources/airm) | https://github.com/silogen/cluster-forge/tree/main/sources/airm |

## Helm Charts

| No | Name | Version | Project |
|----|------|---------|---------|
| 1 | argocd | [8.3.5](https://argoproj.github.io/argo-helm) | https://argoproj.github.io/ |
| 2 | cert-manager | [1.18.2](oci://quay.io/jetstack/charts/cert-manager) | https://cert-manager.io/ |
| 3 | openbao | [0.18.2](https://openbao.github.io/openbao-helm) | https://openbao.org/ |
| 4 | external-secrets | [0.15.1](https://charts.external-secrets.io) | https://external-secrets.io/main/ |
| 5 | gitea | [12.3.0](https://dl.gitea.com/charts/) | https://github.com/go-gitea/gitea |
| 6 | kgateway-crds | [2.1.0-main](oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds) | https://kgateway.dev/ |
| 7 | kgateway | [2.1.0-main](oci://cr.kgateway.dev/kgateway-dev/charts/kgateway) | https://kgateway.dev/ |
| 8 | prometheus-crds | [23.0.0](https://prometheus-community.github.io/helm-charts) | https://github.com/prometheus-community/ |
| 9 | opentelemetry-operator | [0.93.1](https://open-telemetry.github.io/opentelemetry-helm-charts) | https://opentelemetry.io/ |
| 10 | cnpg-operator | [0.26.0](https://cloudnative-pg.github.io/charts) | https://cloudnative-pg.github.io/ |
| 11 | keycloak | [keycloak-old](https://codecentric.github.io/helm-charts) | https://github.com/keycloak/keycloak |
| 12 | kyverno | [3.5.1](https://kyverno.github.io/kyverno/) | https://github.com/kyverno/kyverno |
| 13 | amd-gpu-operator | [1.4.0](https://rocm.github.io/gpu-operator) | https://github.com/ROCm/ROCm |
| 14 | kuberay-operator | [1.4.2](https://ray-project.github.io/kuberay-helm/) | https://github.com/ROCm/ROCm |
| 15 | kueue | [0.13.0](oci://registry.k8s.io/kueue/charts/kueue) | https://kueue.sigs.k8s.io/ |
| 16 | minio-operator | [7.1.1](https://operator.min.io) | https://github.com/minio/operator |
| 17 | minio-tenant | [7.1.1](https://operator.min.io) | https://github.com/minio/operator |
| 18 | airm | [airm](https://github.com/silogen/cluster-forge/tree/main/sources/airm) | https://github.com/silogen/cluster-forge/tree/main/sources/airm |

## Kubernetes Manifests

| No | Name | Version | Project |
|----|------|---------|---------|
| 1 | gateway-api | [1.3.0](https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml) | https://gateway-api.sigs.k8s.io/ |
| 2 | metallb | [0.15.2](https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml) | https://github.com/metallb/metallb/ |
| 3 | otel-lgtm-stack | [otel-lgtm-stack](https://github.com/silogen/docker-otel-lgtm) | https://github.com/grafana/docker-otel-lgtm |
| 4 | rabbitmq | [2.15.0](https://github.com/rabbitmq/cluster-operator/releases/download/v2.15.0/cluster-operator.yml) | https://github.com/rabbitmq/cluster-operator/ |
| 5 | appwrapper | [1.1.2](https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml) | https://github.com/project-codeflare/appwrapper |
| 6 | kaiwo | [0.1.7](https://github.com/silogen/kaiwo/releases/download/v0.1.7/install.yaml) | https://github.com/silogen/kaiwo/ |

## Container Images


## gateway-api images

No container images found in manifest files.

## metallb images

| No | Image |
|----|-------|
| 1 | `quay.io/metallb/controller:v0.15.2` |
| 2 | `quay.io/metallb/speaker:v0.15.2` |

## otel-lgtm-stack images

| No | Image |
|----|-------|
| 1 | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.113.0` |
| 2 | `ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.19.0-alpha` |
| 3 | `ghcr.io/silogen/otel-lgtm-custom:1.0.1` |
| 4 | `quay.io/kiwigrid/k8s-sidecar:1.27.4` |
| 5 | `quay.io/prometheus/node-exporter:v1.9.0` |
| 6 | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0` |

## rabbitmq images

| No | Image |
|----|-------|
| 1 | `rabbitmqoperator/cluster-operator:2.15.0` |

## appwrapper images

| No | Image |
|----|-------|
| 1 | `quay.io/ibm/appwrapper:v1.1.2` |

## kaiwo images

| No | Image |
|----|-------|
| 1 | `ghcr.io/silogen/kaiwo-operator:v0.1.7` |
| 2 | `registry.k8s.io/kube-scheduler:v1.32.0` |
