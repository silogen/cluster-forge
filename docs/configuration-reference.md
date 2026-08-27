# Configuration reference

Cluster-Forge configuration variables used outside Helm chart `values.yaml` files:
root Argo CD `helmParameters`, install scripts, and platform gate helpers.

## Root chart Argo CD helmParameters

| Application | Parameter | Default (root) | Purpose |
|-------------|-----------|----------------|---------|
| `aim-engine` | `clusterRuntimeConfig.enable` | `false` | When `false`, the aim-engine chart does not render `AIMClusterRuntimeConfig`. Set `true` for OpenShift/manual installs that need aim-engine-managed routing (see `docs/openshift/install.sh` and `docs/manual_helm_install/scripts/install_base.sh`). |

Defined in `root/values.yaml` under `apps.<app>.helmParameters`.

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
