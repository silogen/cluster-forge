<!--
Copyright © Advanced Micro Devices, Inc., or its affiliates.

SPDX-License-Identifier: MIT
-->

# HELM CHARTS

Simple instructions to deploy the full AIRM stack (UI/API/Agent) using a helm chart

This helm chart is a combination of 2 charts, one for the AIRM API and UI and another one for the AIRM Agent.

Please refer to the README files in each of those charts for more details, including dependencies, values and specific instructions.

### 1. Install

```
cd helm

# 1. Create output template just to validate (the public domain could be app-dev.silogen.ai, staging.silogen.ai, etc.)
helm template airm ./airm -n airm --create-namespace --set airm-api.airm.appDomain=<PUBLIC-DOMAIN-HERE> > airm-helm-generated.yaml

# 2. Run chart install
helm install airm ./airm -n airm --create-namespace --set airm-api.airm.appDomain=<PUBLIC-DOMAIN-HERE>

# 3. Delete chart if needed
helm delete airm -n airm

# 4. Upgrade when bumping versions
helm upgrade -n airm --set airm-api.airm.appDomain=<PUBLIC-DOMAIN-HERE> airm ./airm
```
