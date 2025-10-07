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

| Field Path                                 | Description                            | Type   | Example / Default                 |
| ------------------------------------------ | -------------------------------------- | ------ | --------------------------------- |
| airm.dispatcher.core.image.repository      | Core dispatcher image repository       | string | `ghcr.io/silogen/airm-dispatcher` |
| airm.dispatcher.core.image.tag             | Core dispatcher image tag              | string | `v2025.08-rc.21`                  |
| airm.dispatcher.core.image.pullPolicy      | Core dispatcher image pull policy      | string | `IfNotPresent`                    |
| airm.dispatcher.core.servicePort           | Core dispatcher service port           | int    | `80`                              |
| airm.dispatcher.heartbeat.image.repository | Heartbeat dispatcher image repository  | string | `ghcr.io/silogen/airm-dispatcher` |
| airm.dispatcher.heartbeat.image.tag        | Heartbeat dispatcher image tag         | string | `v2025.08-rc.21`                  |
| airm.dispatcher.heartbeat.image.pullPolicy | Heartbeat dispatcher image pull policy | string | `IfNotPresent`                    |
| airm.dispatcher.nodes.image.repository     | Nodes dispatcher image repository      | string | `ghcr.io/silogen/airm-dispatcher` |
| airm.dispatcher.nodes.image.tag            | Nodes dispatcher image tag             | string | `v2025.08-rc.21`                  |
| airm.dispatcher.nodes.image.pullPolicy     | Nodes dispatcher image pull policy     | string | `IfNotPresent`                    |
