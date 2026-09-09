# Configuration reference

Cluster Forge configuration variables: root Argo CD `helmParameters`, selected
root `global` keys, install scripts, and platform gate helpers.

## Root chart Argo CD helmParameters

| Application | Parameter | Default (root) | Purpose |
|-------------|-----------|----------------|---------|
| `aim-engine` | `clusterRuntimeConfig.enable` | `'false'` | Quoted string so Argo CD / Helm pass a boolean-looking value without YAML converting it to a boolean. When `'false'`, the aim-engine chart does not render `AIMClusterRuntimeConfig`. Set `'true'` for OpenShift/manual installs that need aim-engine-managed routing (see `docs/openshift/install.sh` and `docs/manual_helm_install/scripts/install_base.sh`). |
| `aim-engine` | `manager.image.repository` | `amdenterpriseai/aim-engine` | aim-engine controller image repository (tag comes from the chart / `repoVersion`). |
| `aim-engine` | `manager.artifactDownloaderImage` | `docker.io/amdenterpriseai/aim-artifact-downloader:v0.2.6` | Full image reference for the artifact-downloader sidecar. The tag includes the `v` prefix. |
| `ai-gateway-discovery` | `controller.bodyAuthMaxRequestBytes` | `4194304` (from `global.aiGateway.bodyAuthMaxRequestBytes`) | Per-model catch-all SecurityPolicy body-authz ceiling. Must match `envoy-gateway-config`'s `aiGateway.bodyAuthMaxRequestBytes`. |
| `envoy-gateway-config` | `aiGateway.bodyAuthMaxRequestBytes` | `4194304` (from `global.aiGateway.bodyAuthMaxRequestBytes`) | Gateway-scoped `ai-gateway-default-deny` `bodyToExtAuth.maxRequestBytes`. See [AI Gateway body-authz request size](#ai-gateway-body-authz-request-size). |

Defined in `root/values.yaml` under `apps.<app>.helmParameters`.

## AI Gateway body-authz request size

`global.aiGateway.bodyAuthMaxRequestBytes` (default `4194304`, 4MiB) is the
shared ceiling for the body-aware extAuth filter on the header-less
(model-in-body) path. A body over this value returns HTTP 413 and skips
authorization (this precedence holds even over `failOpen`). Tune it per
environment in the cluster-values overlay; keep it a positive integer (Helm
renders it through `int64` so a float/scientific-notation value does not
publish `maxRequestBytes: 0`).

`root/values.yaml` wires the same value into both
`controller.bodyAuthMaxRequestBytes` (ai-gateway-discovery) and
`aiGateway.bodyAuthMaxRequestBytes` (envoy-gateway-config). Discovery's
rule-scoped policies override the gateway-scoped one per route, so the two
must stay in step. The chart-local default in
`sources/envoy-gateway-config/values.yaml` is the same number and applies
only if the root helmParameter is omitted.

## AI Gateway webhook TLS (prevention vs heal)

Mainline clusters issue the envoy-ai-gateway mutating webhook serving cert via
cert-manager (`controller.mutatingWebhook.certManager.enable: true` in
`root/values.yaml`). ca-injector keeps `clientConfig.caBundle` aligned with the
issued Certificate.

The heal script below is for legacy genCA clusters, post-cutover recovery, and
operator runbooks when drift still occurs (EAI-8292).

## `scripts/ai-gateway-webhook-health.sh`

Probe and heal the envoy-ai-gateway pod mutating webhook. Defaults match the
`envoy-ai-gateway` chart.

| Variable | Default | Purpose |
|----------|---------|---------|
| `WEBHOOK_NAME` | `envoy-ai-gateway-gateway-pod-mutator.envoy-ai-gateway-system` | `MutatingWebhookConfiguration` resource name |
| `SECRET_NAMESPACE` | `envoy-ai-gateway-system` | Namespace of the webhook TLS secret |
| `SECRET_NAME` | `self-signed-cert-for-mutating-webhook` | Secret containing `ca.crt` |
| `CONTROLLER_NAMESPACE` | `envoy-ai-gateway-system` | AI Gateway controller namespace |
| `CONTROLLER_DEPLOYMENT` | `ai-gateway-controller` | Deployment restarted during heal |
| `GATEWAY_NAMESPACE` | `envoy-gateway-system` | Namespace for probe pods and Envoy data-plane restarts |
| `APPS_GATEWAY_NAME` | `https` | Apps Gateway checked after heal |
| `AI_GATEWAY_NAME` | `ai-gateway` | AI Gateway checked after heal (skipped when absent) |

Flags: `--probe-only` (no heal). Healing always restarts https and ai-gateway Envoy
data-plane Deployments and verifies Gateway `Programmed=True` before exit 0.

## `scripts/platform-gates/`

Post-handoff cluster checks. See [`scripts/platform-gates/README.md`](../scripts/platform-gates/README.md).

| Variable | Default | Purpose |
|----------|---------|---------|
| `PLATFORM_DOMAIN` | *(required)* | Cluster apex domain for HTTPS gate |
| `CLUSTERFORGE_RELEASE` | `unknown` in report | Recorded in gate report metadata only |
| `PLATFORM_GATES_HOST` | `hostname -f` | Hostname recorded in report metadata |
| `PLATFORM_GATES_REPORT` | `~/platform-gates-report.txt` | Output path for `run-all.sh` |
| `PLATFORM_GATES_BLOOM_LOG` | `~/bloom-cli.log` | Bloom log tail on gate failure |
| `PLATFORM_GATES_BLOOM_LOG_TAIL` | `50` | Lines of bloom log included on failure |
| `PLATFORM_GATES_CURL_TIMEOUT` | `30` | Seconds for `https-aiwb-ui.sh` curl |
| `GATEWAY_NAMESPACE` | `envoy-gateway-system` | Namespace for gateway programmed gate |
| `APPS_GATEWAY_NAME` | `https` | Apps Gateway name |
| `AI_GATEWAY_NAME` | `ai-gateway` | AI Gateway name (skipped when absent) |

Webhook gate env vars are inherited from `ai-gateway-webhook-health.sh`.

## `byok/bootstrap.sh`

Installs a minimal cluster-forge on a Kubernetes cluster that already exists.
See [`byok/README.md`](../byok/README.md).

| Flag or variable | Command | Default | Meaning |
|---|---|---|---|
| `--profile <file>` | `install`, `validate` | none, required | Profile file. A path relative to `byok/` also works. |
| `--source github:<ref>` | `install` | the local checkout | Clone cluster-forge at that ref and install from it. |
| `--source <path>` | `install` | the local checkout | Install from another checkout. |
| `--purge` | `remove` | off | Also delete the CRDs of the package, the PVCs in its namespace, and the namespace. |
| `KUBECONFIG` | all | none, required | Path to a cluster-admin kubeconfig. |
| `HELM_TIMEOUT` | all | `10m` | Value for `helm --timeout`. |

## `byok/tests/smoke.sh`

| Variable | Default | Meaning |
|---|---|---|
| `GHCR_PULL_SECRET_JSON` | empty | Docker config JSON for the private dummy image. |
| `AIM_TIMEOUT` | `15m` | How long to wait for the AIMService conditions. |
| `KEEP` | `0` | `1` keeps the `aims-test` namespace after the test. |

## `byok/footprint/footprint.sh`

| Variable | Default | Meaning |
|---|---|---|
| `NAMESPACES` | `cert-manager kserve-system aim-system` | Namespaces to measure. |
