# Blueprint: vLLM Semantic Router

[semantic-router](https://github.com/vllm-project/semantic-router) chooses a
backend model for each request. This blueprint deploys the router, the
dashboard, and the Envoy gateway wiring. Envoy calls the router as an external
processor. The router returns a model name. Envoy sends the request to that
model's backend.

Install it with [`scripts/setup.sh`](scripts/README.md). That page lists the
files, the text replacements, and the API key.

## Before you run the script

- Point kubectl at the cluster. The script reads ConfigMap `cluster-domain` in
  namespace `default`.
- Install mikefarah `yq`, `openssl`, and `git`.
- Clone the cluster-values repository and change to its root. The script writes
  in the current directory. Run it there, not in cluster-forge.

A bloomed cluster already has the Gateway API CRDs, the Envoy Gateway CRDs, the
AI Gateway CRDs, and the shared `https` Gateway. The router starts when no vLLM
backend exists. Requests have a destination after you set a real Service below.

Git prompts on the first push. The user is `devuser`. Read the password from
the cluster:

```bash
kubectl -n cf-gitea get secret gitea-devuser-secret \
    -o jsonpath='{.data.GITEA_DEVUSER_SECRET}' | base64 -d; echo
```

The same user and password sign in to `https://gitea.<domain>`.

## Install

From the root of cluster-values:

```bash
/path/to/cluster-forge/root-extras/blueprints/semantic-router/scripts/setup.sh
```

The script merges `extraApps.semantic-router` into `extra-apps-values.yaml`
and leaves every other extra app in place. It copies the chart values and the
gateway manifests. It writes hostnames `sr-dashboard.<domain>` and
`sr.<domain>`, and it writes the smoke-test model names. It commits and
pushes. It creates Secret `semantic-router-client-keys` when that Secret is
absent, with data key `smoke-client`, and it prints the key once.

Watch the Application:

```bash
kubectl get application semantic-router -n argocd -w
```

`cluster-forge-extras` renders Application `semantic-router` from
`extra-apps-values.yaml`. That Application syncs the chart and the manifests.
`selfHeal: true` restores both from git.

The copies in the overlay are plain files. A later change in this blueprint
does not change a cluster until you run the script again or edit the overlay.

## Real model and Service

The script writes model `smoke-test-model` and Service
`test-vllm.semantic-router.svc`. Replace those names in the overlay after the
script finishes. A later run of `setup.sh` writes the smoke-test names again.
Edit the two files after the last run, then commit and push.

The router config and the Envoy route both name the model. The router emits a
model name. Envoy maps that name to a Service. Set both files.

In `extra-apps/semantic-router/values.yaml`:

| Field | Set it to |
|---|---|
| `config.providers.defaults.model` | model name |
| `config.providers.models[].name` | same model name |
| `config.providers.models[].provider_model_id` | ID the vLLM server expects |
| `config.providers.models[].backend_refs[].endpoint` | `<service>.<namespace>.svc:8000` |
| `config.recipes[].decisions[].modelRefs[].model` | same model name |

In `extra-apps/semantic-router/manifests/gateway-routing.yaml`:

| Field | Set it to |
|---|---|
| header `x-selected-model` | the model `name` |
| `modelNameOverride` | `provider_model_id` |
| Backend hostname | `<service>.<namespace>.svc.cluster.local` |
| Backend port | `8000` |

Keep the two hostnames distinct. `sr-dashboard.<domain>` is the dashboard.
`sr.<domain>` is the router. One hostname for both makes the two HTTPRoutes
conflict.

The dashboard config page can edit models. A save patches the router
ConfigMap. The next self-heal restores that ConfigMap from `values.yaml`. The
dashboard does not write the Envoy Backend. Put the Service address in both
files.

A greenfield cluster uses the same files. Nothing in the platform copies live
vLLM Services into this config.

`config.recipes` ships with one catch-all decision. Config schema is v0.5.
`examples/complexity-routing-example.md` shows a second model and a complexity
signal. Repeat each model in `gateway-routing.yaml`.

## Dashboard

Sign in at `https://sr-dashboard.<domain>` with email `admin@<domain>` and
display name `admin`. Read the password:

```bash
kubectl -n semantic-router get secret semantic-router-dashboard-admin \
    -o jsonpath='{.data.password}' | base64 -d; echo
```

OpenBao stores the account. ExternalSecret
`semantic-router-dashboard-admin` copies it into the namespace before the
dashboard pod starts. The public first-admin form stays closed.

The dashboard creates that admin when the email is absent from its database.
A new password in OpenBao does not replace an existing row. Delete the
dashboard volume and start the pod again to create the account again.

The volume also keeps evaluation runs and saved workflows. The session signing
key is `jwt-secret` in the same Secret.

## Check a decision

Port 8080 is the management API. It has no public route.

```bash
kubectl -n semantic-router port-forward svc/semantic-router 8080:8080
curl localhost:8080/health
curl -sX POST localhost:8080/api/v1/routing/preview \
  -H 'Content-Type: application/json' \
  -d '{"text":"Write a Python function to implement a binary search tree"}'
```

The response field `selected_model` is the model the router selects. Send
client traffic through the gateway. Use the API key as a bearer token:

```bash
curl https://sr.<domain>/... -H "Authorization: Bearer <key>"
```

A missing or invalid key returns 401. The Secret key name becomes
`x-api-key-id`. Give each client its own key name.

## Request path

The shared `https` Gateway terminates TLS and forwards `sr.<domain>` to
`sr-gateway`. `sr-gateway` is a Gateway in namespace `semantic-router`. It runs
the external processor, the model route, and the API-key policy. The router
listens for that processor on port 50051. The router does not proxy the
request.

| Object | File | Role |
|---|---|---|
| `HTTPRoute` `semantic-router-gateway` | `gateway-routing.yaml` | `sr.<domain>` on the shared `https` Gateway, forwarded to `sr-gateway` |
| `Gateway` `sr-gateway` | `sr-gateway.yaml` | HTTP data plane for this router |
| `EnvoyExtensionPolicy` `sr-gateway-extproc` | `sr-gateway-extproc.yaml` | calls the router on port 50051 |
| `AIGatewayRoute` `semantic-router` | `gateway-routing.yaml` | matches `x-selected-model` |
| `AIServiceBackend` and `Backend` | `gateway-routing.yaml` | one pair per model |
| `SecurityPolicy` `semantic-router-apikey` | `gateway-routing.yaml` | requires the API key |

`SecurityPolicy` targets `sr-gateway`. It cannot target an `AIGatewayRoute`.
Leave the catch-all rule last. Envoy needs a match before it calls the
external processor.

Commented examples in `gateway-routing.yaml` show a retry policy, weighted
backends, and OpenAI and Anthropic upstreams. An external HTTPS backend needs
a `BackendTLSPolicy`. Set `schema.name` on the `AIServiceBackend` to `OpenAI`
or `Anthropic`. For a cluster-held provider key, set `api_key_env` on the
model endpoint in `values.yaml`.

## Quota

`manifests/aigw-extras/quota.yaml` is optional. `setup.sh` does not copy it.
Copy it to `extra-apps/semantic-router/manifests/quota.yaml` when you want a
per-key limit. `examples/quota-tiers-example.md` shows per-model limits.

Quota needs app `envoy-ai-gateway-ratelimit` in the overlay `enabledApps`
list. Without that app, a `QuotaPolicy` still loads and requests succeed. The
Service name `envoy-ai-gateway-ratelimit.envoy-gateway-system` is fixed in the
chart. Keep `shadowMode: true` until the counters match the limit you want.
Set `modelName` to the route's `modelNameOverride`.

The controller build for this blueprint counts requests for a distinct client
bucket. Leave token limits unset.

## Direct Envoy fallback

`manifests/gateway-routing-direct-envoy.yaml` is for a cluster that lacks the
AI Gateway CRDs. A bloomed cluster has those CRDs. `setup.sh` does not copy
this file. To use it, copy it over `gateway-routing.yaml` and omit
`quota.yaml` and the `sr-gateway*.yaml` files. This path has no token quota
and no per-model schema translation.

## Storage

`persistence.storageClassName: ""` omits the field. The cluster default
StorageClass applies. The value `"-"` stores an explicit empty class, and the
PVC stays Pending. Set a real class name when the cluster has no default.

## Chart commit

`targetRevision` in `extraApps.yaml` and both image tags in `values.yaml` use
one commit. Config schema is v0.5. Bump the chart commit and both image tags
together. The chart default tag is `latest`.
