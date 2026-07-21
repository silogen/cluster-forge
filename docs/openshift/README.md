*************
* AIWB STACK
*************

1. Requirements

This scenario is expecting a valid Openshift cluster where AMD GPU Operator can be installed from Openshift Software Catalog, or it will be installed from this stack 

2. Deploy AIWB

Deploy the AI WorkBench stack with all tools needed on a Openshift cluster

```bash
# Use any temporary folder that it will be used to download the release package into
export CLUSTER_FORGE_DIR=".tmp/cf"

# Set desired CF version to be used on the installation
export CLUSTER_FORGE_VERSION=v2.2.0

# Deploy using a subshell
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/install.sh | bash
```

---

3. Expected output

Finally this is the expected output from console after all components have been installed. Consider that PUBLIC_IP_DOMAIN will be replaced by Openshift main endpoint URL

```bash
✅ AIWB application is ready

💡 Verification commands:
   kubectl get pods -n keycloak
   kubectl get pods -n aiwb
   kubectl get pods -n kaiwo-system
   kubectl get pods -n keda
   kubectl get pods -n otel-lgtm-stack
   kubectl get pods -n cnpg-system
   kubectl get pods -n amd-gpu-operator
   kubectl get cluster --all-namespaces

💡 Access:
   Gateway IP: 192.168.127.240:8080
   AIWB UI: https://aiwbui.PUBLIC_IP_DOMAIN.nip.io
   AIWB API: https://aiwbapi.PUBLIC_IP_DOMAIN.nip.io
   Keycloak: https://kc.PUBLIC_IP_DOMAIN.nip.io

   Ensure DNS points aiwbui.PUBLIC_IP_DOMAIN.nip.io, aiwbapi.PUBLIC_IP_DOMAIN.nip.io, and kc.PUBLIC_IP_DOMAIN.nip.io to 192.168.127.240

💡 Keycloak Admin Credentials:
   Username: silogen-admin
   Password: placeholder
   Admin Console: http://PUBLIC_IP_DOMAIN.nip.io:8080/admin

💡 AIWB User Login:
   Username: devuser@PUBLIC_IP_DOMAIN.nip.io
   Password: placeholder

📊 Observability (Grafana, Prometheus, Loki, Tempo):
   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000
   Access Grafana at: http://localhost:3000
   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090
   Access Prometheus at: http://localhost:9090

ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md
```

---

4. Installation steps

The `install.sh` script runs through the numbered phases below. Each phase prints a banner like `[STEP N]` as it progresses. Before step 1, the script resolves the cluster domain from the first argument or auto-detects it from the OpenShift ingress config (`ingresses.config.openshift.io/cluster`).

| Step | Phase | Description |
|------|-------|-------------|
| 1 | Downloading cluster-forge release | Downloads and extracts the pinned cluster-forge release tarball (`CLUSTER_FORGE_VERSION`), fetches `manual_helm_install` secrets and scripts from GitHub, and applies post-clone patches (e.g. envoy-gateway SecurityPolicy `failOpen: true`). |
| 2 | Custom SecurityContextConstraints (SCCs) | Applies OpenShift custom SCC manifests from `extra/scc.yaml` so pods with non-default security contexts (e.g. OpenTelemetry operator with `seccompProfile: RuntimeDefault`) can be scheduled. |
| 3 | local-path provisioner & default StorageClass | Ensures dynamic storage is available: installs the local-path provisioner if missing, creates a `default` StorageClass when absent, and marks it as the cluster default. |
| 4 | Kuberay operator | Installs the Kuberay operator for Ray cluster management. |
| 5 | CloudNativePG database operator | Installs the CloudNativePG (CNPG) operator in `cnpg-system` and waits for it to be ready. Skipped when `PLUGGABLE_DB=true`. |
| 6 | Appwrapper | Deploys the Appwrapper controller and CRDs in `appwrapper-system`. |
| 7 | Kyverno (policy management) | Installs Kyverno with OpenShift-specific RBAC (cluster-reader binding for reports-controller) and waits for all Kyverno controllers to become available. |
| 8 | Kyverno base + storage policies | Installs base security and `storage-local-path` Kyverno cluster policies. |
| 9 | Extra OpenShift Kyverno policies (SCC + HTTPRoute→Route) | Installs per-namespace SCC generation, HTTPRoute-to-OpenShift-Route automation (with inter-namespace route host sharing), and orphaned-SCC cleanup policies. |
| 10 | Workspace StorageClasses (multinode, mlstorage) | Creates `multinode` and `mlstorage` StorageClasses for workspace PVCs if they do not already exist. |
| 11 | Prometheus Operator CRDs | Installs Prometheus Operator CRDs when not already present on the cluster (OpenShift may ship them). |
| 12 | cert-manager | Installs cert-manager with CRDs and waits for deployments and webhook certificates to be ready. |
| 13 | OpenTelemetry operator | Installs the OpenTelemetry Operator. MetalLB installation is skipped on OpenShift. |
| 14 | External Secrets Operator | Installs External Secrets Operator, waits for CRDs to be established, and clears the kubectl API discovery cache. |
| 15 | Gateway API CRDs | Skipped by default on OpenShift (`SKIP_GATEWAY_API_CRDS=true`). Set `SKIP_GATEWAY_API_CRDS=false` to install Gateway API CRDs early on clusters that do not ship them. |
| 16 | OpenBao (secrets management) | Installs OpenBao, applies config, runs the init job (initialize/unseal), and configures the `openbao-secret-store` ClusterSecretStore for ExternalSecrets. |
| 17 | OTEL LGTM stack (Grafana/Loki/Tempo/Prometheus) | Deploys the observability stack (Prometheus, Grafana, Loki, Tempo, Mimir) with OpenShift-specific fixes (node-exporter port, AMD GPU metrics scrape namespace). |
| 18 | KEDA (event-driven autoscaling) | Installs KEDA operator, metrics server, and admission webhooks. |
| 19 | Kedify OTEL scaler | Installs the Kedify OpenTelemetry metrics scaler for KEDA. |
| 20 | MetalLB configuration (skipped on OpenShift) | Skipped; OpenShift provides its own load balancer and routing. |
| 21 | Envoy Gateway (skipped on OpenShift; creating namespaces) | Skips Envoy Gateway installation; creates `envoy-gateway-system` and `cluster-auth` namespaces referenced by other components. OpenShift Routes (via Kyverno) replace Gateway API routing. |
| 22 | KServe (model serving) | Installs KServe CRDs and operator in RawDeployment mode, or skips if KServe is already running (e.g. under RHOAI in `redhat-ods-applications`). |
| 23 | AMD GPU operator (NFD + KMM + device plugin) | Installs the AMD GPU Operator (Node Feature Discovery, Kernel Module Management, device plugin) if not already present. |
| 24 | AMD GPU operator config (DeviceConfig) | Applies a DeviceConfig in the operator namespace when no DeviceConfig exists anywhere in the cluster. |
| 25 | AMD GPU node labelling (NodeFeatureRule fallback) | Applies a standalone NodeFeatureRule to label AMD GPU nodes when hardware is detected but the `amd-gpu` label is missing. |
| 26 | AIM Engine (controller + CRDs) | Installs AIM Engine CRDs, the AIM Engine operator (routing disabled for OpenShift), and renders the AIM Cluster Model Source manifest. |
| 27 | AIWB infrastructure (namespaces + secrets) | Creates required namespaces and applies AIWB standalone secrets, CNPG credentials, and object-storage credentials (respecting `PLUGGABLE_DB` / `PLUGGABLE_S3` modes). |
| 28 | cluster-auth shim (standalone) | Deploys an in-memory cluster-auth REST shim so AIWB can manage API key groups without OpenBao-backed persistence. |
| 29 | AIWB database cluster (CNPG) | Provisions the in-cluster PostgreSQL cluster for AIWB via CNPG and waits for a healthy state. Skipped when `PLUGGABLE_DB=true`. |
| 30 | Keycloak (identity & access management) | Starts Keycloak with an in-cluster CNPG database or external PostgreSQL (`PLUGGABLE_DB=true`), configured for the cluster domain. |
| 31 | SeaweedFS (object storage) | Installs SeaweedFS (operator, instance, S3 config, bucket init) as the in-cluster S3-compatible store, or creates an in-cluster redirect Service to external MinIO when `PLUGGABLE_S3=true`. |
| 32 | Wait for Keycloak readiness | Waits for the Keycloak CNPG cluster and deployment to become ready, patches readiness probe timing, and exits with diagnostics on timeout. Skipped when `PLUGGABLE_DB=true`. |
| 33 | AIWB application | Installs the main AI WorkBench Helm chart in standalone mode with domain, Keycloak, database, and object-storage settings. |
| 34 | AI Gateway Discovery | Installs the AI Gateway Discovery controller with route hostname `ai.<DOMAIN>`. |
| 35 | Rabbit MQ | Installs the RabbitMQ cluster operator in `rabbitmq-system`. |
| 36 | Kueue | Installs the Kueue job queueing controller and applies cluster configuration from `kueue-config`. |
| 37 | Kaiwo CRDs | Installs Kaiwo custom resource definitions in `kaiwo-system`. |
| 38 | Kaiwo | Installs the Kaiwo operator and applies `kaiwo-config` manifests (with ExternalSecret API version fixes). |
| 39 | Apply OpenShift Routes (AIWB UI/API + Keycloak) | Applies native OpenShift Routes from `extra/routes.yaml` for AIWB UI, API, and Keycloak, substituting the cluster domain. |
| 40 | Cleanup (remove downloaded cluster-forge sources) | Removes the downloaded cluster-forge release directory from `CLUSTER_FORGE_DIR` to free disk space. |
