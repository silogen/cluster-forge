<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# HELM CHARTS

Simple instructions to deploy the AIRM Agent using helm chart.
The Agent is a lightweight Go-based service that runs on compute clusters to manage Kubernetes resources and communicate cluster status to the AIRM API via RabbitMQ messaging.

### 1. Requirements

The following external components must be available in the Kubernetes cluster before the helm chart can be installed.

- Accessible RabbitMQ cluster (must be the same cluster used by AIRM API)
- Kaiwo installed on the cluster (along with all its dependencies)
- cert-manager installed on the cluster (for webhook certificate management)

### 2. Install

```
cd helm/airm/charts

# 1. Create output template just to validate
helm template agent ./agent -n airm --create-namespace > agent-helm-generated.yaml

# 2. Run chart install
helm install agent ./agent -n airm --create-namespace

# 3. Delete chart if needed
helm delete agent -n airm

# 4. Upgrade when bumping versions
helm upgrade -n airm agent ./agent
```

---

### 3. Helm Settings

| Field Path                                | Description                                                  | Type   | Example / Default                                       |
| ----------------------------------------- | ------------------------------------------------------------ | ------ | ------------------------------------------------------- |
| airm.image.repository                     | Shared image repository for agent and webhook                | string | ``                                                      |
| airm.image.tag                            | Shared image tag for agent and webhook                       | string | ``                                                      |
| airm.image.pullPolicy                     | Shared image pull policy                                     | string | `IfNotPresent`                                          |
| airm.imagePullSecrets                     | Image pull secrets for private registries                    | array  | `[]`                                                    |
| airm.agent.servicePort                    | Agent service port                                           | int    | `8000`                                                  |
| airm.agent.rabbitmq.host                  | RabbitMQ host                                                | string | `"airm-infra-rabbitmq-rabbitmq.airm.svc.cluster.local"` |
| airm.agent.rabbitmq.port                  | RabbitMQ port                                                | string | `"5672"`                                                |
| airm.agent.rabbitmq.userSecretName        | Secret containing RabbitMQ connection credentials            | string | `"airm-rabbitmq-common-vhost-user"`                     |
| airm.agent.resources                      | Agent resource requests and limits (standard format)         | object | See values.yaml                                         |
| airm.webhook.servicePort                  | Webhook service port                                         | int    | `9443`                                                  |
| airm.webhook.resources                    | Webhook resource requests and limits (standard format)       | object | See values.yaml                                         |
| airm.utilities.netcat.image.repository    | Netcat image repository                                      | string | `busybox`                                               |
| airm.utilities.netcat.image.tag           | Netcat image tag                                             | string | `1.37.0`                                                |
| airm.utilities.netcat.image.pullPolicy    | Netcat image pull policy                                     | string | `IfNotPresent`                                          |
| airm.utilities.curl.image.repository      | Curl image repository                                        | string | `curlimages/curl`                                       |
| airm.utilities.curl.image.tag             | Curl image tag                                               | string | `8.16.0`                                                |
| airm.utilities.curl.image.pullPolicy      | Curl image pull policy                                       | string | `IfNotPresent`                                          |
| airm.additionalClusterRoles.platformAdmin | Additional cluster roles for the Platform Administrator role | array  | `[]`                                                    |
| airm.additionalClusterRoles.projectMember | Additional cluster roles for the Project Member role         | array  | `[]`                                                    |
