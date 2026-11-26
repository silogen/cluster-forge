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

The script does not need OpenBao, External Secrets Operator, or a
ClusterSecretStore. Those three are only for dashboard way 2 below. A bloomed
cluster has all three.

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
gateway chart. It writes hostnames `sr-dashboard.<domain>` and `sr.<domain>`.
It writes three smoke-test model ids and one smoke-test Service. It commits
and pushes. It creates Secret `semantic-router-client-keys` when that Secret
is absent, with data key `smoke-client`, and it prints the key once.

Watch the Application:

```bash
kubectl get application semantic-router -n argocd -w
```

`cluster-forge-extras` renders Application `semantic-router` from
`extra-apps-values.yaml`. That Application syncs the router chart and the
gateway chart. `selfHeal: true` restores both from git.

The copies in the overlay are the files Argo CD reads. A later change in this
blueprint does not change a cluster. A later run of the script keeps each file
that exists. To take a new copy, delete the file in the overlay, then run the
script again.

## Real model and Service

Edit three entries in `extra-apps/semantic-router/values.yaml`:

| Entry | Role |
|---|---|
| `models.small` | Easy prompts |
| `models.medium` | Catch-all, and the default model |
| `models.large` | Hard prompts |

Each entry has `id` and `endpoint`. `id` is the router model name, the id the
backend expects, the `x-selected-model` value, and the quota `modelName`.
`endpoint` is `<service>.<namespace>.svc.cluster.local:<port>`.

YAML anchors copy those fields into `config`. Leave the `*modelSmall`,
`*modelMedium`, `*modelLarge`, `*endpointSmall`, `*endpointMedium`, and
`*endpointLarge` lines in place. The gateway chart reads the same entries.
Change the three entries, then commit and push. The three ids must differ.

The script writes `smoke-test-small`, `smoke-test-medium`, and
`smoke-test-large`. All three endpoints point at
`test-vllm.semantic-router.svc.cluster.local:8000`. The ids differ so the
gateway objects can all be created.

Keep the two hostnames distinct. `sr-dashboard.<domain>` is the dashboard.
`sr.<domain>` is the router. One hostname for both makes the two HTTPRoutes
conflict.

`routing.parentRef` is the shared Gateway that serves the router hostname.
`routing.gatewayClassName` is the GatewayClass of the router's own Gateway. The
defaults match a bloomed cluster.

The dashboard config page can edit models. A save patches the router
ConfigMap. The next self-heal restores that ConfigMap from `values.yaml`.
The dashboard does not write the Envoy Backend. Put the Service address in
`models.<tier>.endpoint`.

A new cluster uses the same files. Nothing in the platform copies live
vLLM Services into this config.

`examples/complexity-routing-example.md` describes the decision rules in
`config.recipes`.

## Dashboard

As shipped, the dashboard has no admin, and `allowOpenBootstrap` stays false.
The router works. Nobody can log in until you pick one way below.

Ways 1 and 2 use the same `dashboard.jwtSecret` and `dashboard.extraEnv`
blocks. Those blocks ship commented out. Uncomment them after the Secret
exists. With the blocks set and the Secret absent, the dashboard pod stays
in `CreateContainerConfigError`.

The dashboard creates the admin when the email is absent from its database.
A new password does not replace an existing row. Delete the dashboard volume
and start the pod again to create the account again.

The volume also keeps evaluation runs and saved workflows. The session signing
key is `jwt-secret` in the same Secret.

### 1. Startup admin from a Secret

Use this on any cluster. Create Secret `semantic-router-dashboard-admin` in
namespace `semantic-router` before the first sync. The keys are `email`,
`name`, `password`, and `jwt-secret`.

```bash
kubectl -n semantic-router create secret generic semantic-router-dashboard-admin \
  --from-literal=email=admin@<your domain> \
  --from-literal=name=admin \
  --from-literal=password="$(openssl rand -hex 16)" \
  --from-literal=jwt-secret="$(openssl rand -hex 32)"
```

Do not put this Secret in the overlay repo. The repo would then contain the
password in plain text.

Uncomment `dashboard.jwtSecret` and `dashboard.extraEnv` in
`extra-apps/semantic-router/values.yaml`. Commit and push.

Sign in at `https://sr-dashboard.<domain>` with that email and password.

### 2. Startup admin from OpenBao

Use this on a bloomed cluster. It is way 1, with External Secrets Operator
creating the Secret. This way needs OpenBao, External Secrets Operator, and
ClusterSecretStore `openbao-secret-store`. A bloomed cluster has all three.

`openbao-config` in the same cluster-forge release defines the four OpenBao
paths. Run this script from the root of cluster-values, after `setup.sh`:

```bash
/path/to/cluster-forge/root-extras/blueprints/semantic-router/scripts/setup-dashboard-admin.sh
```

The script copies the ExternalSecret into the gateway chart. It sets
`dashboard.jwtSecret` and `dashboard.extraEnv` in
`extra-apps/semantic-router/values.yaml`. It commits and pushes. The file is
necessary only to read the Secret from OpenBao. `setup.sh` does not copy it.

Sign in at `https://sr-dashboard.<domain>` with email `admin@<domain>` and
display name `admin`. Read the password:

```bash
kubectl -n semantic-router get secret semantic-router-dashboard-admin \
    -o jsonpath='{.data.password}' | base64 -d; echo
```

### 3. Open bootstrap

Use this for a short demo only. Set `allowOpenBootstrap: true` and create the
admin in the web form. The form is public and has no authentication until an
admin exists. Set `allowOpenBootstrap: false` again after you create the
admin. Do not use this on a cluster that stays up.

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

| Object | Template | Role |
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

Commented examples in `chart/templates/gateway-routing.yaml` show a retry
policy, weighted backends, and OpenAI and Anthropic upstreams. An external
HTTPS backend needs a `BackendTLSPolicy`. Set `schema.name` on the
`AIServiceBackend` to `OpenAI` or `Anthropic`.

## Quota

Set `quota.enabled: true` in `values.yaml`. The chart renders one
`perModelQuotas` entry per model. `modelName` is that model's `id`. Every key
shares `quota.limit` and `quota.duration`. The default duration is `1h`.
`quota.shadowMode` is `true` by default.

Quota needs `routing.mode: aigw` and app `envoy-ai-gateway-ratelimit` in the
overlay `enabledApps` list. Without that app, a `QuotaPolicy` still loads and
requests succeed. The Service name
`envoy-ai-gateway-ratelimit.envoy-gateway-system` is fixed in the chart. Keep
`quota.shadowMode: true` until the counters match the limit you want.

The controller build for this blueprint counts requests for a distinct client
bucket. Leave token limits unset.

`examples/quota-tiers-example.md` shows a different limit per model and a
higher limit for one named client. For that policy, set `quota.enabled` to
false and add your own `QuotaPolicy` template. Two policies on the same
backends both apply.

## Direct Envoy fallback

Set `routing.mode: envoy` on a cluster that lacks the AI Gateway CRDs. A
bloomed cluster has those CRDs and keeps `routing.mode: aigw`.

In envoy mode the chart routes each model to its Service. It does not render
`sr-gateway`, the AI Gateway route, or the quota policy. This path has no
token quota and no per-model schema translation.

`manifests/gateway-routing-direct-envoy.yaml` is an annotated example. The
chart does not apply it. The comments show retries, weighted backends, and
external providers.

## Storage

`persistence.storageClassName: ""` omits the field. The cluster default
StorageClass applies. The value `"-"` stores an explicit empty class, and the
PVC stays Pending. Set a real class name when the cluster has no default.

## Chart commit

`targetRevision` in `extraApps.yaml` and both image tags in `values.yaml` use
one commit. Config schema is v0.5. Bump the chart commit and both image tags
together. The chart default tag is `latest`.
