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

| Field Path                                                  | Description                                            | Type   | Example / Default                                          |
| ----------------------------------------------------------- | ------------------------------------------------------ | ------ | ---------------------------------------------------------- |
| secretgenerator.image.repository                            | Docker image repository for secret generator           | string | `ghcr.io/silogen/kubectl`                                  |
| secretgenerator.image.tag                                   | Docker image tag                                       | string | `latest`                                                   |
| secretgenerator.image.pullPolicy                            | Image pull policy                                      | string | `IfNotPresent`                                             |
| kgateway.namespace                                          | Namespace for kgateway resources                       | string | `kgateway-system`                                          |
| kgateway.gatewayName                                        | Gateway name                                           | string | `https`                                                    |
| kgateway.airmapi.servicePort                                | Service port for airmapi                               | int    | `80`                                                       |
| kgateway.airmapi.prefixValue                                | URL prefix for airmapi service                         | string | `airmapi`                                                  |
| kgateway.airmui.servicePort                                 | Service port for airmui                                | int    | `80`                                                       |
| kgateway.airmui.prefixValue                                 | URL prefix for airmui service                          | string | `airmui`                                                   |
| keycloak.prefixUrl                                          | URL prefix for keycloak                                | string | `kc`                                                       |
| keycloak.keycloakClientId                                   | Client ID for keycloak                                 | string | `354a0fa1-35ac-4a6d-9c4d-d661129c2cd0`                     |
| keycloak.namespace                                          | Namespace where keycloak is deployed                   | string | `keycloak`                                                 |
| keycloak.serviceName                                        | Service name for keycloak                              | string | `keycloak`                                                 |
| keycloak.servicePort                                        | Service port for keycloak                              | int    | `8080`                                                     |
| airm.appDomain                                              | Public IP or domain for airm                           | string | `PUBLIC-IP`                                                |
| airm.externalSecretStore.airm.name                          | Secret store name for airm                             | string | `airm-secret-store`                                        |
| airm.externalSecretStore.minio.name                         | Secret store name for minio                            | string | `k8s-secret-store`                                         |
| airm.externalSecretStore.keycloak.name                      | Secret store name for keycloak                         | string | `keycloak-secret-store`                                    |
| airm.postgresql.cnpg.image                                  | PostgreSQL container image                             | string | `ghcr.io/cloudnative-pg/postgresql:17`                     |
| airm.postgresql.cnpg.instance                               | Number of PostgreSQL instances                         | int    | `1`                                                        |
| airm.postgresql.cnpg.resources.limits.cpu                   | CPU limit for PostgreSQL container                     | string | `"2"`                                                      |
| airm.postgresql.cnpg.resources.limits.memory                | Memory limit for PostgreSQL container                  | string | `1Gi`                                                      |
| airm.postgresql.cnpg.resources.requests.cpu                 | CPU request for PostgreSQL container                   | string | `"1"`                                                      |
| airm.postgresql.cnpg.resources.requests.memory              | Memory request for PostgreSQL container                | string | `512Mi`                                                    |
| airm.postgresql.cnpg.storage.size                           | Storage size for PostgreSQL                            | string | `50Gi`                                                     |
| airm.postgresql.cnpg.storage.storageClass                   | Storage class for PostgreSQL                           | string | `default`                                                  |
| airm.postgresql.cnpg.walStorage.size                        | WAL storage size for PostgreSQL                        | string | `50Gi`                                                     |
| airm.postgresql.cnpg.walStorage.storageClass                | WAL storage class for PostgreSQL                       | string | `default`                                                  |
| airm.rabbitmqBackup.enabled                                 | Enable RabbitMQ backup                                 | bool   | `false`                                                    |
| airm.rabbitmqBackup.image                                   | RabbitMQ backup container image                        | string | `ghcr.io/silogen/rabbitmq-backup:0.1`                      |
| airm.rabbitmqBackup.replicas                                | Number of replicas for RabbitMQ backup                 | int    | `1`                                                        |
| airm.rabbitmqBackup.resources.limits.memory                 | Memory limit for RabbitMQ backup                       | string | `512Mi`                                                    |
| airm.rabbitmqBackup.resources.requests.cpu                  | CPU request for RabbitMQ backup                        | string | `250m`                                                     |
| airm.rabbitmqBackup.resources.requests.memory               | Memory request for RabbitMQ backup                     | string | `256Mi`                                                    |
| airm.rabbitmqBackup.persistence.storage                     | Persistent storage size for RabbitMQ backup            | string | `20Gi`                                                     |
| airm.rabbitmqBackup.persistence.storageClassName            | Storage class name for RabbitMQ backup                 | string | `default`                                                  |
| airm.rabbitmqBackup.cronJob.resources.limits.memory         | Memory limit for cron job of RabbitMQ backup           | string | `512Mi`                                                    |
| airm.rabbitmqBackup.cronJob.resources.requests.cpu          | CPU request for cron job of RabbitMQ backup            | string | `250m`                                                     |
| airm.rabbitmqBackup.cronJob.resources.requests.memory       | Memory request for cron job of RabbitMQ backup         | string | `256Mi`                                                    |
| airm.frontend.prefixUrl                                     | Frontend URL prefix                                    | string | `airmui`                                                   |
| airm.frontend.image.repository                              | Frontend image repository                              | string | `ghcr.io/silogen/airm-ui`                                  |
| airm.frontend.image.tag                                     | Frontend image tag                                     | string | `v2025.08-rc.21`                                           |
| airm.frontend.image.pullPolicy                              | Frontend image pull policy                             | string | `IfNotPresent`                                             |
| airm.frontend.servicePort                                   | Frontend service port                                  | int    | `80`                                                       |
| airm.frontend.resources.limits.memory                       | Memory limit for frontend                              | string | `4Gi`                                                      |
| airm.frontend.resources.requests.cpu                        | CPU request for frontend                               | string | `500m`                                                     |
| airm.frontend.resources.requests.memory                     | Memory request for frontend                            | string | `4Gi`                                                      |
| airm.workloads.prefixUrl                                    | URL prefix for workloads manager                       | string | `workspaces`                                               |
| airm.backend.image.repository                               | Backend API image repository                           | string | `ghcr.io/silogen/airm-api`                                 |
| airm.backend.image.tag                                      | Backend API image tag                                  | string | `v2025.08-rc.21`                                           |
| airm.backend.image.pullPolicy                               | Backend API image pull policy                          | string | `IfNotPresent`                                             |
| airm.backend.initContainers.initMigrationScripts.repository | Init container image for migration scripts             | string | `ghcr.io/silogen/airm-api`                                 |
| airm.backend.initContainers.initMigrationScripts.tag        | Init container image tag for migration scripts         | string | `v2025.08-rc.21`                                           |
| airm.backend.initContainers.initMigrationScripts.pullPolicy | Init container image pull policy for migration scripts | string | `IfNotPresent`                                             |
| airm.backend.initContainers.liquibaseMigrate.repository     | Liquibase migrate init container image                 | string | `quay.io/lib/liquibase`                                    |
| airm.backend.initContainers.liquibaseMigrate.tag            | Liquibase migrate image tag                            | string | `latest`                                                   |
| airm.backend.initContainers.liquibaseMigrate.pullPolicy     | Liquibase migrate image pull policy                    | string | `IfNotPresent`                                             |
| airm.backend.initContainers.chartsRegistration.repository   | Charts registration init container image               | string | `ghcr.io/silogen/airm-api`                                 |
| airm.backend.initContainers.chartsRegistration.tag          | Charts registration image tag                          | string | `v2025.08-rc.21`                                           |
| airm.backend.initContainers.chartsRegistration.pullPolicy   | Charts registration image pull policy                  | string | `IfNotPresent`                                             |
| airm.backend.servicePort                                    | Backend API service port                               | int    | `80`                                                       |
| airm.backend.servicePortMetrics                             | Backend API metrics service port                       | int    | `9009`                                                     |
| airm.backend.env.dbPort                                     | Database port                                          | int    | `5432`                                                     |
| airm.backend.env.rabbitmqPort                               | RabbitMQ port                                          | int    | `5672`                                                     |
| airm.backend.env.minio_url                                  | Minio service URL                                      | string | `http://minio.minio-tenant-default.svc.cluster.local:80`   |
| airm.backend.env.minio_bucket                               | Minio bucket name                                      | string | `default-bucket`                                           |
| airm.backend.env.prometheus_url                             | Prometheus service URL                                 | string | `http://lgtm-stack.otel-lgtm-stack.svc.cluster.local:9090` |
| airm.backend.resources.limits.memory                        | Memory limit for backend API container                 | string | `1Gi`                                                      |
| airm.backend.resources.requests.cpu                         | CPU request for backend API container                  | string | `500m`                                                     |
| airm.backend.resources.requests.memory                      | Memory request for backend API container               | string | `1Gi`                                                      |
| airm.backend.securityContext.allowPrivilegeEscalation       | Security context: allow privilege escalation           | bool   | `false`                                                    |
| airm.backend.securityContext.runAsNonRoot                   | Security context: run container as non-root            | bool   | `true`                                                     |
| airm.backend.securityContext.runAsUser                      | Security context: user ID to run container as          | int    | `1000`                                                     |
| airm.backend.securityContext.seccompProfile.type            | Security context: seccomp profile type                 | string | `RuntimeDefault`                                           |
