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

| Field Path                                            | Description                                                     | Type   | Example / Default                                          |
| ----------------------------------------------------- | --------------------------------------------------------------- | ------ | ---------------------------------------------------------- |
| kgateway.namespace                                    | Namespace for kgateway resources                                | string | `kgateway-system`                                          |
| kgateway.gatewayName                                  | Gateway name                                                    | string | `https`                                                    |
| kgateway.airmapi.servicePort                          | Service port for airmapi                                        | int    | `80`                                                       |
| kgateway.airmapi.prefixValue                          | URL prefix for airmapi service                                  | string | `airmapi`                                                  |
| kgateway.airmui.servicePort                           | Service port for airmui                                         | int    | `80`                                                       |
| kgateway.airmui.prefixValue                           | URL prefix for airmui service                                   | string | `airmui`                                                   |
| airm.includeDemoSetup                                 | Include the demo organization and project setup when installing | bool   | `true`                                                     |
| airm.appDomain                                        | Public IP or domain for airm                                    | string | `PUBLIC-IP`                                                |
| airm.keycloak.publicUrl                               | Public URL to access keycloak                                   | string | `https://kc.{{ .Values.airm.appDomain }}`                  |
| airm.keycloak.internalUrl                             | Internal URL to access keycloak                                 | string | `http://keycloak.keycloak.svc.cluster.local:8080`          |
| airm.keycloak.clientId                                | Client ID to access keycloak                                    | string | `354a0fa1-35ac-4a6d-9c4d-d661129c2cd0`                     |
| airm.keycloak.realm                                   | Keycloak realm for authentication                               | string | `airm`                                                     |
| airm.keycloak.adminClientSecretName                   | Secret containing the Keycloak admin client secret              | string | `airm-keycloak-admin-client`                               |
| airm.keycloak.uiClientSecretName                      | Secret containing the Keycloak UI client secret                 | string | `airm-keycloak-ui-creds`                                   |
| airm.keycloak.userCredentialsSecretName               | Secret containing the Keycloak user credentials                 | string | `airm-user-credentials`                                    |
| airm.postgresql.host                                  | PostgreSQL host address                                         | string | `airm-cnpg-rw.airm.svc.cluster.local`                      |
| airm.postgresql.port                                  | PostgreSQL port number                                          | int    | `5432`                                                     |
| airm.postgresql.userSecretName                        | Secret containing the PostgreSQL credentials                    | string | `airm-cnpg-user`                                           |
| airm.rabbitmq.host                                    | RabbitMQ host address                                           | string | `airm-infra-rabbitmq-rabbitmq.airm.svc.cluster.local`      |
| airm.rabbitmq.port                                    | RabbitMQ port number                                            | int    | `5672`                                                     |
| airm.rabbitmq.managementPort                          | RabbitMQ management port number                                 | int    | `15672`                                                    |
| airm.rabbitmq.adminUserSecretName                     | Secret containing the RabbitMQ admin user credentials           | string | `airm-rabbitmq-admin`                                      |
| airm.prometheus.url                                   | Prometheus service URL                                          | string | `http://lgtm-stack.otel-lgtm-stack.svc.cluster.local:9090` |
| airm.frontend.image.repository                        | Frontend image repository                                       | string | `amdenterpriseai/airm-ui`                                  |
| airm.frontend.image.tag                               | Frontend image tag                                              | string | `v2025.08-rc.21`                                           |
| airm.frontend.image.pullPolicy                        | Frontend image pull policy                                      | string | `IfNotPresent`                                             |
| airm.frontend.servicePort                             | Frontend service port                                           | int    | `80`                                                       |
| airm.frontend.resources.limits.memory                 | Memory limit for frontend                                       | string | `4Gi`                                                      |
| airm.frontend.resources.requests.cpu                  | CPU request for frontend                                        | string | `500m`                                                     |
| airm.frontend.resources.requests.memory               | Memory request for frontend                                     | string | `4Gi`                                                      |
| airm.frontend.secretName                              | Name of the secret containing variables for the frontend        | string | `airm-secrets-airm`                                        |
| airm.backend.image.repository                         | Backend API image repository                                    | string | `amdenterpriseai/airm-api`                                 |
| airm.backend.image.tag                                | Backend API image tag                                           | string | `v2025.08-rc.21`                                           |
| airm.backend.image.pullPolicy                         | Backend API image pull policy                                   | string | `IfNotPresent`                                             |
| airm.backend.servicePort                              | Backend API service port                                        | int    | `80`                                                       |
| airm.backend.servicePortMetrics                       | Backend API metrics service port                                | int    | `9009`                                                     |
| airm.backend.resources.limits.memory                  | Memory limit for backend API container                          | string | `1Gi`                                                      |
| airm.backend.resources.requests.cpu                   | CPU request for backend API container                           | string | `500m`                                                     |
| airm.backend.resources.requests.memory                | Memory request for backend API container                        | string | `1Gi`                                                      |
| airm.backend.securityContext.allowPrivilegeEscalation | Security context: allow privilege escalation                    | bool   | `false`                                                    |
| airm.backend.securityContext.runAsNonRoot             | Security context: run container as non-root                     | bool   | `true`                                                     |
| airm.backend.securityContext.runAsUser                | Security context: user ID to run container as                   | int    | `1000`                                                     |
| airm.backend.securityContext.seccompProfile.type      | Security context: seccomp profile type                          | string | `RuntimeDefault`                                           |
| airm.utilities.netcat.image.repository                | Netcat image repository                                         | string | `busybox`                                                  |
| airm.utilities.netcat.image.tag                       | Netcat image tag                                                | string | `1.37.0`                                                   |
| airm.utilities.netcat.image.pullPolicy                | Netcat image pull policy                                        | string | `IfNotPresent`                                             |
| airm.utilities.curl.image.repository                  | Curl image repository                                           | string | `curlimages/curl`                                          |
| airm.utilities.curl.image.tag                         | Curl image tag                                                  | string | `8.16.0`                                                   |
| airm.utilities.curl.image.pullPolicy                  | Curl image pull policy                                          | string | `IfNotPresent`                                             |
| airm.utilities.liquibase.image.repository             | Liquibase image repository                                      | string | `docker.io/liquibase/liquibase`                            |
| airm.utilities.liquibase.image.tag                    | Liquibase image tag                                             | string | `4.31`                                                     |
| airm.utilities.liquibase.image.pullPolicy             | Liquibase image pull policy                                     | string | `IfNotPresent`                                             |
