# AMD Enterprise AI reference stack


1. Requirements

This scenario is expecting a valid Openshift cluster where AMD GPU Operator can be installed from Openshift Software Catalog, or it will be installed from this stack 

2. Deploy AMD Enterprise AI reference stack

Deploy the stack with all tools needed on a Openshift cluster

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
| 2 | Custom SecurityContextConstraints (SCCs) | Applies OpenShift custom SCC manifests from `extra/01-scc.yaml` so pods with non-default security contexts (e.g. OpenTelemetry operator with `seccompProfile: RuntimeDefault`) can be scheduled. |
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
| 21 | Envoy AI Gateway | Serves `https://ai.<DOMAIN>`, the single endpoint every deployed model answers on, with the model chosen per request from the `x-ai-eg-backend` and `x-ai-eg-model` headers. Ordinary web traffic is unaffected and keeps using OpenShift Routes generated by Kyverno; only inference needs this, because a Route cannot match on headers. Installs the Envoy Gateway and AI Gateway control planes, the OpenShift-specific SCC/RBAC/Route from `extra/06-ai-gateway.yaml`, and a copy of the router's wildcard certificate as `cluster-tls`. Skipped on clusters that do not serve `route.openshift.io`. See "AI gateway" below. |
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
| 39 | Apply OpenShift Routes (AIWB UI/API + Keycloak) | Applies native OpenShift Routes from `extra/09-routes.yaml` for AIWB UI, API, and Keycloak, substituting the cluster domain. |
| 40 | Cleanup (remove downloaded cluster-forge sources) | Removes the downloaded cluster-forge release directory from `CLUSTER_FORGE_DIR` to free disk space. |

### The `extra/` manifests

Everything `install.sh` applies that is not rendered from a cluster-forge chart lives in `extra/`. The numeric prefix is the order the script applies them in, so reading the directory top to bottom tells you what lands on the cluster and when, without grepping the script.

| File | Applied in | What it is |
|------|-----------|------------|
| `01-scc.yaml` | 2 | Every custom SCC, the `anyuid` grants, the Kyverno SCC-generator RBAC, and the aim-system SCCs for the detector DaemonSets and discovery Jobs |
| `02-local-path-provisioner-scc.yaml` | 3 | Lets the local-path provisioner mount hostPath |
| `03-local-path-helper-pod-selinux.yaml` | 3 | Merge-patch, not a manifest: runs the helper pod as `spc_t` so it can mkdir under `/var/opt` |
| `04-local-path-access-mode-scoped.yaml` | 8 | Scopes cluster-forge's RWX→RWO mutation to the local-path StorageClasses |
| `05-kyverno.yaml` | 9 | Per-project SCC generation, HTTPRoute→Route conversion, orphaned-SCC cleanup, and the RBAC each needs |
| `06-ai-gateway.yaml` | 21 | The AI gateway's SCC, RBAC and passthrough Route |
| `07-ai-gateway-values.yaml` | 21 | Helm values for the `envoy-gateway` chart, not a manifest |
| `08-amd-gpu-nodefeaturerule.yaml` | 25 | NodeFeatureRule labelling AMD GPU nodes |
| `09-routes.yaml` | 39 | Routes for the AIWB UI/API and Keycloak |

Order is load-bearing in two places. Across files, RBAC and SCCs must exist before the workloads they admit. Within `05-kyverno.yaml`, each RBAC ClusterRole must precede the policy that depends on it, because Kyverno's webhooks validate those permissions at admission time and reject the policy otherwise.

When `install.sh` is run from a checkout it reads these files from the `extra/` directory beside it. Piped straight from `curl` it has no directory, so it fetches each one from `docs/openshift/extra/` on cluster-forge `main` and aborts with the filename and URL if one is missing.

That only works because the two directories hold the same files under the same names, prefix included. Renaming a file here without renaming it upstream, or the other way round, breaks the piped install for everyone while leaving checkout runs working — so it fails for whoever is least able to debug it. Rename in both places or in neither.

---

5. Chart versions

Two different versions are in play and they are easy to confuse.

`CLUSTER_FORGE_VERSION` selects which release tarball is downloaded. It does **not** select chart versions: the tarball is a catalogue that carries several versions of the same chart side by side (for example `sources/kserve` holds both `v0.15.2` and `v0.16.0`).

Which one gets installed is declared by the release itself, in `root/values.yaml`, as `apps.<name>.path` for charts that live in the tarball and `apps.<name>.repoVersion` for the ones pulled from an OCI registry. The OCI charts — AIWB, AIM Engine, Kaiwo, the AI gateway discovery controller — are not in the tarball at all, and their numbering is unrelated to the cluster-forge release: at v2.2.2 AIWB is 2.0.0, AIM Engine is 0.2.5 and Kaiwo is v0.2.1. There is no `2.2.2` tag for any of them, so a chart version cannot be derived from the release number.

`install.sh` reads `repoVersion` out of the downloaded release for every OCI chart, so bumping `CLUSTER_FORGE_VERSION` picks up whatever that release pins, with nothing to edit by hand.

To install a chart that no release references yet, override it per app. The variable is the app key uppercased with dashes turned into underscores:

```bash
CF_VERSION_AIWB=2.0.1 CF_VERSION_AI_GATEWAY_DISCOVERY=2.0.1 ./install.sh
```

The override is announced in the output, since it puts the cluster on a combination the release was not tested with.

Charts that come from the tarball still have their version written into the path in `install.sh`. In every case that is the newest version the tarball holds, with one deliberate exception: `external-secrets` is installed at `0.19.2` while v2.2.2 declares `0.15.1`. Keep that in mind before making those dynamic too — doing it naively would downgrade it.

---

6. AI gateway

Every model deployed on the cluster is served from one hostname, `https://ai.<DOMAIN>`. The model is chosen per request from two headers rather than from the URL:

```bash
curl -k -X POST https://ai.<DOMAIN>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-ai-eg-backend: <workload-uuid>' \
  -H 'x-ai-eg-model: <model-name>' \
  -d '{"messages":[{"role":"user","content":"Hello"}],"stream":false}'
```

The workload UUID is the `airm.silogen.ai/workload-id` label on the InferenceService:

```bash
kubectl get inferenceservice -A -o custom-columns=\
  'NAME:.metadata.name,UUID:.metadata.labels.airm\.silogen\.ai/workload-id'
```

Nothing has to be configured per model. The AI Gateway Discovery controller (step 34) watches InferenceServices and generates the AIGatewayRoute for each one as it becomes ready.

This is the one place where OpenShift's own routing is not enough: a Route matches on host and path only, so a set of models sharing a hostname cannot be told apart by it. Everything else on the cluster keeps using Routes generated from HTTPRoutes by Kyverno, and models stay reachable on their individual `workloads.<DOMAIN>` URLs in parallel.

The step needs an OpenShift Route to be reachable at all and an OpenShift SCC to get its pods admitted, so it runs only where `route.openshift.io` is served. Anywhere else it is skipped with a message and nothing is installed.

### How this differs from the RKE2 reference clusters

Those clusters chain two Envoy gateways on a single `:443` VIP. A front-door `https` Gateway owns the whole domain and hands AI traffic down by SNI, without decrypting it:

```
*.<DOMAIN> -> Gateway "https" (LoadBalancer front door)
                |- listener https             TLS terminate   -> apps
                |- listener k8s-passthrough   TLS passthrough -> kube API
                '- listener ai-passthrough    TLS passthrough -> TLSRoute
                                                                    |
                   Gateway "ai-gateway" (ClusterIP, own Envoy)  <---'
                     terminates cluster-tls, ext_proc dispatch,
                     InferencePool -> EPP -> model pod
```

On OpenShift the HAProxy router already **is** that front door, so the `https` Gateway is deliberately not installed — installing a second front door is exactly what would collide with cluster ingress. Only the second tier is added, and the TLSRoute is replaced by one passthrough Route:

```
ai.<DOMAIN>:443 -> HAProxy router (passthrough by SNI, terminates nothing)
                     -> Service ai-gateway:443
                        -> Gateway ai-gateway (terminates cluster-tls)
                           -> ext_proc x-ai-eg-backend
                              -> InferencePool -> EPP -> model pod
```

Everything below the passthrough point is identical on both, which is why the same cluster-forge chart serves both with only three patched lines (exact listener hostname, no `cluster-bloom/first-node` nodeSelector, and a capped Envoy `concurrency`).

The Route is TLS-passthrough, so HAProxy presents no certificate of its own and Envoy terminates TLS with the `cluster-tls` secret in `envoy-gateway-system`. The installer populates it by **copying** the wildcard certificate the router already serves. It is a copy, not a reference, so it goes stale when the ingress-operator rotates the original — the symptom is a TLS error on `ai.<DOMAIN>` alone, with every other hostname fine.

Re-running `install.sh` refreshes it, and so does copying the secret by hand if a full re-run is not wanted:

```bash
kubectl get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tls.crt
kubectl get secret router-certs-default -n openshift-ingress -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/tls.key
kubectl create secret tls cluster-tls -n envoy-gateway-system \
  --cert=/tmp/tls.crt --key=/tmp/tls.key --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f -
rm -f /tmp/tls.crt /tmp/tls.key
```

(If the IngressController has a `spec.defaultCertificate`, use that secret name instead of `router-certs-default`.)

`-k` is needed for as long as the router serves the cluster's default self-signed certificate. Install a CA-signed certificate on the IngressController and re-run the script above, and it applies to this endpoint too.

Requests are not authenticated yet. The gateway ignores the `Authorization` header because ext_authz is not enabled: the cluster-auth shim (step 28) speaks REST on 8081, while the SecurityPolicy the chart ships expects gRPC on 50051.
