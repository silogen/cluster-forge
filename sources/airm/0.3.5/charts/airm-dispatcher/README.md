<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# HELM CHARTS

Simple instructions to deploy AIRM dispatcher application using helm chart.
The dispatcher can be run on a compute cluster, which may or may not be the same as the one hosting the AIRM API and UI.

### 1. Requirements

The following external components must be available in the Kubernetes cluster before the helm chart can be installed.

- Accessible RabbitMQ cluster (must be the same cluster used by AIRM API).
- Kaiwo installed on the cluster (along with all its dependencies)

### 2. Install

```
cd helm/airm/charts

# 1. Create output template just to validate (the public domain could be app-dev.silogen.ai, staging.silogen.ai, etc.)
helm template airm-dispatcher ./airm-dispatcher -n airm --create-namespace > airm-dispatcher-helm-generated.yaml

# 2. Run chart install
helm install airm-dispatcher ./airm-dispatcher -n airm --create-namespace

# 3. Delete chart if needed
helm delete airm-dispatcher -n airm

# 4. Upgrade when bumping versions
helm upgrade -n airm --set airm-dispatcher ./airm-dispatcher
```

---

### 3. Helm Settings

| Field Path                                  | Description                                                  | Type    | Example / Default                 |
|---------------------------------------------|--------------------------------------------------------------|---------|-----------------------------------|
| airm.dispatcher.image.repository            | Dispatcher image repository                                  | string  | `amdenterpriseai/airm-dispatcher` |
| airm.dispatcher.image.tag                   | Dispatcher image tag                                         | string  | `v2025.08-rc.21`                  |
| airm.dispatcher.image.pullPolicy            | Dispatcher image pull policy                                 | string  | `IfNotPresent`                    |
| airm.dispatcher.servicePort                 | Dispatcher service port                                      | int     | `80`                              |
| airm.utilities.netcat.image.repository      | Netcat image repository                                      | string  | `busybox`                         |
| airm.utilities.netcat.image.tag             | Netcat image tag                                             | string  | `1.37.0`                          |
| airm.utilities.netcat.image.pullPolicy      | Netcat image pull policy                                     | string  | `IfNotPresent`                    |
| airm.utilities.curl.image.repository        | Curl image repository                                        | string  | `curlimages/curl`                 |
| airm.utilities.curl.image.tag               | Curl image tag                                               | string  | `8.16.0`                          |
| airm.utilities.curl.image.pullPolicy        | Curl image pull policy                                       | string  | `IfNotPresent`                    |
| airm.additionalClusterRoles.platformAdmin   | Additional cluster roles for the Platform Administrator role | array   | `[]`                              |
| airm.additionalClusterRoles.projectMember   | Additional cluster roles for the Project Member role         | array   | `[]`                              |
