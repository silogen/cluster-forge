<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# HELM CHARTS

Simple instructions to deploy AIRM UI and API applications using helm chart

### 1. Requirements

The following external components must be available in the Kubernetes cluster before the helm chart can be installed.

- API Gateway implementation (e.g. KGateway)
- Keycloak with the expected `airm` realm installed
- Valid S3 compatible file storage service (e.g. MinIO)
- RabbitMQ operator
- Cert Manager operator
- External Secret operator
- CNPG operator
- OTEL LGTM stack installed on the cluster

### 2. Install

```
cd helm/airm/charts

# 1. Create output template just to validate (the public domain could be app-dev.silogen.ai, staging.silogen.ai, etc.)
helm template airm-api ./airm-api -n airm --create-namespace --set airm.appDomain=<PUBLIC-DOMAIN-HERE> > airm-api-helm-generated.yaml

# 2. Run chart install
helm install airm-api ./airm-api -n airm --create-namespace --set airm.appDomain=<PUBLIC-DOMAIN-HERE>

# 3. Delete chart if needed
helm delete airm-api -n airm

# 4. Upgrade when bumping versions
helm upgrade -n airm --set airm.appDomain=<PUBLIC-DOMAIN-HERE> airm-api ./airm-api
```

---

### 3. Helm Settings

| Field Path                                                                    | Description                                                     | Type   | Example / Default                                                                                 |
|-------------------------------------------------------------------------------|-----------------------------------------------------------------| ------ |---------------------------------------------------------------------------------------------------|
| secretgenerator.image.repository                                              | Docker image repository for secret generator                    | string | `ghcr.io/silogen/kubectl`                                                                         |
| secretgenerator.image.tag                                                     | Docker image tag                                                | string | `latest`                                                                                          |
| secretgenerator.image.pullPolicy                                              | Image pull policy                                               | string | `IfNotPresent`                                                                                    |
| kgateway.namespace                                                            | Namespace for kgateway resources                                | string | `kgateway-system`                                                                                 |
| kgateway.gatewayName                                                          | Gateway name                                                    | string | `https`                                                                                           |
| kgateway.airmapi.servicePort                                                  | Service port for airmapi                                        | int    | `80`                                                                                              |
| kgateway.airmapi.prefixValue                                                  | URL prefix for airmapi service                                  | string | `airmapi`                                                                                         |
| kgateway.airmui.servicePort                                                   | Service port for airmui                                         | int    | `80`                                                                                              |
| kgateway.airmui.prefixValue                                                   | URL prefix for airmui service                                   | string | `airmui`                                                                                          |
| kgateway.workloads.prefixValue                                                | URL prefix for deployed workloads                               | string | `workspaces`                                                                                      |
| aims.otelCollector.exporters.otlphttp.endpoint                                | Open Telemetry collector endpoint url for inference metrics     | string | `http://lgtm-stack.otel-lgtm-stack.svc:4318`                                                      |
| aims.otelCollector.image                                                      | Base image for Open Telemetry Collector sidecar                 | string | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.113.0` |
| aims.otelCollector.receivers.prometheus.config.scrape_configs.scrape_interval | Inference metrics scraping interval                             | string | `20s`                                                                                             |
| airm.includeDemoSetup                                                         | Include the demo organization and project setup when installing | bool   | `true`                                                                                            |
| airm.appDomain                                                                | Public IP or domain for airm                                    | string | `PUBLIC-IP`                                                                                       |
| airm.externalSecretStore.airm.name                                            | Secret store name for airm                                      | string | `airm-secret-store`                                                                               |
| airm.externalSecretStore.minio.name                                           | Secret store name for minio                                     | string | `k8s-secret-store`                                                                                |
| airm.externalSecretStore.keycloak.name                                        | Secret store name for keycloak                                  | string | `keycloak-secret-store`                                                                           |
| airm.keycloak.publicUrl                                                       | Public URL to access keycloak                                   | string | `https://kc.{{ .Values.airm.appDomain }}`                                                         |
| airm.keycloak.internalUrl                                                     | Internal URL to access keycloak                                 | string | `http://keycloak.keycloak.svc.cluster.local:8080`                                                 |
| airm.keycloak.clientId                                                        | Client ID to access keycloak                                    | string | `354a0fa1-35ac-4a6d-9c4d-d661129c2cd0`                                                            |
| airm.keycloak.realm                                                           | Keycloak realm for authentication                               | string | `airm`                                                                                            |
| airm.postgresql.cnpg.image                                                    | PostgreSQL container image                                      | string | `ghcr.io/cloudnative-pg/postgresql:17`                                                            |
| airm.postgresql.cnpg.instance                                                 | Number of PostgreSQL instances                                  | int    | `1`                                                                                               |
| airm.postgresql.cnpg.resources.limits.cpu                                     | CPU limit for PostgreSQL container                              | string | `"2"`                                                                                             |
| airm.postgresql.cnpg.resources.limits.memory                                  | Memory limit for PostgreSQL container                           | string | `1Gi`                                                                                             |
| airm.postgresql.cnpg.resources.requests.cpu                                   | CPU request for PostgreSQL container                            | string | `"1"`                                                                                             |
| airm.postgresql.cnpg.resources.requests.memory                                | Memory request for PostgreSQL container                         | string | `512Mi`                                                                                           |
| airm.postgresql.cnpg.storage.size                                             | Storage size for PostgreSQL                                     | string | `50Gi`                                                                                            |
| airm.postgresql.cnpg.storage.storageClass                                     | Storage class for PostgreSQL                                    | string | `default`                                                                                         |
| airm.postgresql.cnpg.walStorage.size                                          | WAL storage size for PostgreSQL                                 | string | `50Gi`                                                                                            |
| airm.postgresql.cnpg.walStorage.storageClass                                  | WAL storage class for PostgreSQL                                | string | `default`                                                                                         |
| airm.rabbitmq.replicas                                                        | Number of replicas for the RabbitMQ cluster                     | int    | `1`                                                                                               |
| airm.rabbitmq.resources.limits.cpu                                            | CPU limit for for the RabbitMQ cluster                          | string | `1`                                                                                               |
| airm.rabbitmq.resources.limits.memory                                         | Memory limit for for the RabbitMQ cluster                       | string | `1Gi`                                                                                             |
| airm.rabbitmq.resources.requests.cpu                                          | CPU request for the RabbitMQ cluster                            | string | `500m`                                                                                            |
| airm.rabbitmq.resources.requests.memory                                       | Memory request for the RabbitMQ cluster                         | string | `1Gi`                                                                                             |
| airm.rabbitmq.persistence.storage                                             | Persistent storage size for the RabbitMQ cluster                | string | `20Gi`                                                                                            |
| airm.rabbitmq.persistence.storageClassName                                    | Storage class name for the RabbitMQ cluster                     | string | `default`                                                                                         |
| airm.rabbitmq.backup.enabled                                                  | Enable RabbitMQ backup                                          | bool   | `false`                                                                                           |
| airm.rabbitmq.backup.image                                                    | RabbitMQ backup container image                                 | string | `amdenterpriseai/rabbitmq-backup:0.1`                                                             |
| airm.rabbitmq.backup.resources.limits.memory                                  | Memory limit for cron job of RabbitMQ backup                    | string | `512Mi`                                                                                           |
| airm.rabbitmq.backup.resources.requests.cpu                                   | CPU request for cron job of RabbitMQ backup                     | string | `250m`                                                                                            |
| airm.rabbitmq.backup.resources.requests.memory                                | Memory request for cron job of RabbitMQ backup                  | string | `256Mi`                                                                                           |
| airm.frontend.image.repository                                                | Frontend image repository                                       | string | `amdenterpriseai/airm-ui`                                                                         |
| airm.frontend.image.tag                                                       | Frontend image tag                                              | string | `v2025.08-rc.21`                                                                                  |
| airm.frontend.image.pullPolicy                                                | Frontend image pull policy                                      | string | `IfNotPresent`                                                                                    |
| airm.frontend.servicePort                                                     | Frontend service port                                           | int    | `80`                                                                                              |
| airm.frontend.resources.limits.memory                                         | Memory limit for frontend                                       | string | `4Gi`                                                                                             |
| airm.frontend.resources.requests.cpu                                          | CPU request for frontend                                        | string | `500m`                                                                                            |
| airm.frontend.resources.requests.memory                                       | Memory request for frontend                                     | string | `4Gi`                                                                                             |
| airm.backend.image.repository                                                 | Backend API image repository                                    | string | `amdenterpriseai/airm-api`                                                                        |
| airm.backend.image.tag                                                        | Backend API image tag                                           | string | `v2025.08-rc.21`                                                                                  |
| airm.backend.image.pullPolicy                                                 | Backend API image pull policy                                   | string | `IfNotPresent`                                                                                    |
| airm.backend.servicePort                                                      | Backend API service port                                        | int    | `80`                                                                                              |
| airm.backend.servicePortMetrics                                               | Backend API metrics service port                                | int    | `9009`                                                                                            |
| airm.backend.env.dbPort                                                       | Database port                                                   | int    | `5432`                                                                                            |
| airm.backend.env.rabbitmqPort                                                 | RabbitMQ port                                                   | int    | `5672`                                                                                            |
| airm.backend.env.minioUrl                                                     | Minio service URL                                               | string | `http://minio.minio-tenant-default.svc.cluster.local:80`                                          |
| airm.backend.env.minioBucket                                                  | Minio bucket name                                               | string | `default-bucket`                                                                                  |
| airm.backend.env.prometheusUrl                                                | Prometheus service URL                                          | string | `http://lgtm-stack.otel-lgtm-stack.svc.cluster.local:9090`                                        |
| airm.backend.env.clusterAuthUrl                                               | Cluster auth service URL                                        | string | `http://cluster-auth.cluster-auth.svc.cluster.local:8081`                                         |
| airm.backend.resources.limits.memory                                          | Memory limit for backend API container                          | string | `1Gi`                                                                                             |
| airm.backend.resources.requests.cpu                                           | CPU request for backend API container                           | string | `500m`                                                                                            |
| airm.backend.resources.requests.memory                                        | Memory request for backend API container                        | string | `1Gi`                                                                                             |
| airm.backend.securityContext.allowPrivilegeEscalation                         | Security context: allow privilege escalation                    | bool   | `false`                                                                                           |
| airm.backend.securityContext.runAsNonRoot                                     | Security context: run container as non-root                     | bool   | `true`                                                                                            |
| airm.backend.securityContext.runAsUser                                        | Security context: user ID to run container as                   | int    | `1000`                                                                                            |
| airm.backend.securityContext.seccompProfile.type                              | Security context: seccomp profile type                          | string | `RuntimeDefault`                                                                                  |
| airm.utilities.netcat.image.repository                                        | Netcat image repository                                         | string | `busybox`                                                                                         |
| airm.utilities.netcat.image.tag                                               | Netcat image tag                                                | string | `1.37.0`                                                                                          |
| airm.utilities.netcat.image.pullPolicy                                        | Netcat image pull policy                                        | string | `IfNotPresent`                                                                                    |
| airm.utilities.curl.image.repository                                          | Curl image repository                                           | string | `curlimages/curl`                                                                                 |
| airm.utilities.curl.image.tag                                                 | Curl image tag                                                  | string | `8.16.0`                                                                                          |
| airm.utilities.curl.image.pullPolicy                                          | Curl image pull policy                                          | string | `IfNotPresent`                                                                                    |
| airm.utilities.liquibase.image.repository                                     | Liquibase image repository                                      | string | `docker.io/liquibase/liquibase`                                                                   |
| airm.utilities.liquibase.image.tag                                            | Liquibase image tag                                             | string | `4.31`                                                                                            |
| airm.utilities.liquibase.image.pullPolicy                                     | Liquibase image pull policy                                     | string | `IfNotPresent`                                                                                    |
