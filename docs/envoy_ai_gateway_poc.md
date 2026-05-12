# Envoy AI Gateway v0.6.0 — POC Notes and TODOs

This document captures the state of the Envoy AI Gateway proof-of-concept running in the
local Kind cluster (`cluster-forge-local`), the workarounds applied to get it working, and
the remaining steps needed to make it fully GitOps-managed and portable to a hosted cluster.

## What the POC proves

End-to-end routing of OpenAI-compatible inference requests through Envoy AI Gateway v0.6.0
to a KServe-hosted Qwen/Qwen3-0.6B model, with per-request token cost tracking via the
ext-proc sidecar.

Verified with:
```bash
curl -k --resolve "aim.localhost.local:443:172.19.255.200" \
  -X POST https://aim.localhost.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 10}'
# → HTTP 200, Qwen/Qwen3-0.6B response
```

## Architecture

```
curl → Envoy Gateway (HTTPS :443, *.localhost.local)
         │
         ├─ ext-proc sidecar (ai-gateway-extproc:v0.6.0)
         │    reads request body, extracts model name,
         │    sets x-ai-eg-model header for routing
         │
         └─ routes to: Backend qwen3-0-6b-cpu
              → wb-aim-d760c43c-9e4156bd-predictor.workbench.svc:80
                (KServe InferenceService running Qwen/Qwen3-0.6B on CPU)
```

The extension server (`ai-gateway-controller`) is called by Envoy Gateway's
`PostTranslateModify` hook during xDS translation. It inserts the ext-proc filter into the
listener and adds the ext-proc UDS cluster to the cluster list.

## Two bugs fixed in ai-gateway v0.6.0

`sources/envoy-ai-gateway/patches/0001-fix-hcm-lookup-skip-non-hcm-filter-chains.patch`
documents both fixes. Upstream issue: neither `insertRouterLevelAIGatewayExtProc` nor
`insertRequestHeaderToMetadataFilter` handled filter chains without an
`HttpConnectionManager` (e.g. the `EmptyCluster` default-reject chain that Envoy Gateway
always generates for TLS listeners). Both returned errors instead of continuing, which
caused the entire xDS translation to fail.

The fix in both cases is a one-line change: `return err` / `return fmt.Errorf(...)` →
`continue`. The equivalent functions elsewhere in the codebase (`patchListenerWithInferencePoolFilters`,
`findListenerRouteConfigs`) already used `continue` correctly.

## Critical config: `translation.includeAll`

Envoy Gateway's extension server only forwards listener/route data to the extension server
if explicitly configured. Without this, the extension server receives empty slices and
cannot insert the ext-proc filter.

Required in `sources/envoy-gateway/v1.7.1/values.yaml`:
```yaml
extensionManager:
  hooks:
    xdsTranslator:
      post:
        - Translation
      translation:
        listener:
          includeAll: true
        route:
          includeAll: true
```

This is already committed to the Gitea `main` branch (commit `075b1c07`) and to the
GitHub branch `EAI-5821-add-envoy-ai-gateway` (commit `e4374de1`).

## Out-of-band changes in the live cluster (not in GitOps)

These changes were applied directly via `kubectl` and are **lost on cluster reset**:

### 1. Patched controller image

The `ai-gateway-controller` deployment was patched to use a locally-built image with the
two bug fixes applied:

```
Image:           docker.io/library/ai-gateway-controller:patched
ImagePullPolicy: Never
```

The image was built from `/tmp/ai-gateway-patch/` (a clone of github.com/envoyproxy/ai-gateway
at tag v0.6.0 with the two-line patch applied) and loaded into the Kind cluster's containerd:

```bash
docker build -f Dockerfile.controller-patch -t ai-gateway-controller:patched .
docker save ai-gateway-controller:patched | \
  docker exec -i cluster-forge-local-control-plane \
  ctr --namespace k8s.io images import -
kubectl rollout restart deployment/ai-gateway-controller -n envoy-ai-gateway-system
```

### 2. TLSRoute deleted from cluster

A `TLSRoute` named `k8s-passthrough` (for Kubernetes API passthrough) existed in the live
cluster but its source YAML (`sources/envoy-gateway-config/templates/tlsroute-k8s-passthrough.yaml`)
was not present in Gitea. It created a TLS passthrough filter chain on the HTTPS listener
that triggered the v0.6.0 bug. It was deleted directly:

```bash
kubectl delete tlsroute k8s-passthrough -n default
```

ArgoCD's `envoy-gateway-config` app has no `prune: true`, so it did not re-create it.

---

## TODOs to fully GitOps-ify for a hosted cluster

### TODO 1: Build and push the patched controller image to a registry

The locally-loaded image must be published to a registry the cluster can pull from.

```bash
# Apply the patch to a clean clone
git clone --branch v0.6.0 https://github.com/envoyproxy/ai-gateway.git
cd ai-gateway
git apply /path/to/0001-fix-hcm-lookup-skip-non-hcm-filter-chains.patch

# Build and push (substitute your registry)
docker build -f manifests/charts/ai-gateway-helm/Dockerfile \
  -t <registry>/ai-gateway-controller:v0.6.0-hcm-fix .
docker push <registry>/ai-gateway-controller:v0.6.0-hcm-fix
```

Then update `sources/envoy-ai-gateway/v0.6.0/values.yaml`:
```yaml
controller:
  image:
    repository: <registry>/ai-gateway-controller
    tag: "v0.6.0-hcm-fix"
  imagePullPolicy: IfNotPresent
```

Alternatively, watch for an upstream v0.6.1 release that includes the fix and upgrade to it.

### TODO 2: Push the `includeAll` config and Helm fix to Gitea `main`

The Gitea `main` branch currently has the `includeAll` config (commit `075b1c07`) and the
TLSRoute deletion (commit `228f540f`) applied out-of-band. The GitHub branch has the Helm
template fix (`f36a845f`) and the `aim-gateway` chart (`67e9c45e`) which are not yet in
Gitea `main`. These need to be reconciled.

### TODO 3: Wire the `aim-gateway` chart as an ArgoCD app

The `sources/eai-infra/aim-gateway/0.1.0/` chart (AIGatewayRoute + Backend + AIServiceBackend)
needs an ArgoCD Application pointing to it. Add it to the cluster's app-of-apps config
(e.g. in `initial-cf-values`) with appropriate namespace (`envoy-ai-gateway-system`) and
sync wave (after `envoy-ai-gateway`, sync wave > -5).

The chart's `values.yaml` currently hardcodes the Qwen3-0.6B backend. Update it for
the target cluster's InferenceService name/namespace before deploying.

### TODO 4: Remove the TLSRoute for k8s API passthrough (or add it properly)

The `k8s-passthrough` TLSRoute was deleted from the cluster to work around the v0.6.0 bug.
Once the patched image is deployed (TODO 1), the bug no longer applies and the TLSRoute can
be re-added if needed. If re-adding, include its source YAML in the repo so ArgoCD manages it.

### TODO 5: Upstream the fix

Consider opening a PR or issue against github.com/envoyproxy/ai-gateway with the patch.
The fix is trivial and clearly correct — the same pattern is already used in three other
functions in the same package.
