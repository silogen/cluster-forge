# Blueprint: vLLM Semantic Router

[semantic-router](https://github.com/vllm-project/semantic-router) routes
requests to backend models based on request content. This blueprint deploys the
router and dashboard. Envoy calls the router as an external processor to select
a backend model.

Files fetched into your cluster-values overlay repo:

| File | Goes to | Contains |
|---|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml` | the ArgoCD Application envelope |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` | the chart config you edit |
| `manifests/gateway-routing.yaml` | `extra-apps/semantic-router/manifests/gateway-routing.yaml` | the routes and backends you edit |
| `manifests/dashboard-admin-externalsecret.yaml` | `extra-apps/semantic-router/manifests/dashboard-admin-externalsecret.yaml` | ExternalSecret that copies the dashboard admin from OpenBao |
| `manifests/aigw-extras/sr-gateway*.yaml` | `extra-apps/semantic-router/manifests/` (flattened, no `aigw-extras/`) | a dedicated Envoy data plane for the router — not edited per deployment, see "Routing traffic through the router" |
| `manifests/aigw-extras/quota.yaml` | `extra-apps/semantic-router/manifests/` (flattened) | per-API-key token quota — optional, see "Quota" |
| `manifests/gateway-routing-direct-envoy.yaml` | *(fallback, not fetched by default)* | no-AI-Gateway version, see "No AI Gateway? Direct-Envoy fallback" — if used, skip the `aigw-extras/` row above entirely |

## Prerequisites

- Gateway API CRDs, the Envoy Gateway CRDs (`EnvoyExtensionPolicy`), the AI
  Gateway CRDs (`AIGatewayRoute`, `AIServiceBackend`, `QuotaPolicy`), and an
  `https` Gateway in `envoy-gateway-system` — all present on any bloomed cluster.
- A reachable vLLM backend serving the model you want to route to. The router
  deploys fine without one, it just has nothing to route to.
- A default StorageClass, or a real class name set in `values.yaml` (see below).
- **For token quota enforcement (`manifests/aigw-extras/quota.yaml`) only:** the
  `envoy-ai-gateway-ratelimit` app — optional, opt-in, cluster-forge core, not
  installed by default. Add `envoy-ai-gateway-ratelimit` to your cluster
  overlay's `enabledApps`. Without it, `QuotaPolicy` still loads and every
  request still succeeds — it fails open — but nothing is ever throttled. See
  "Quota" below before assuming a missing 429 means you're under budget.

## Taking it into use

1. Get the Gitea credentials. Writing to the overlay repo means logging in as
   `devuser`, the account bootstrap creates and makes an owner of the
   `cluster-org` org. Its password is generated at install time and kept in a
   Secret on the cluster:

   ```bash
   kubectl -n cf-gitea get secret gitea-devuser-secret \
       -o jsonpath='{.data.GITEA_DEVUSER_SECRET}' | base64 -d
   ```

   Username `devuser`, password as printed above. Git prompts for both on the
   first push, and the same pair logs you into the Gitea web UI at
   `https://gitea.<domain>`.

2. Clone your cluster-values overlay repo from that Gitea and pull the
   blueprint files into it:

   ```bash
   git clone https://gitea.<domain>/cluster-org/cluster-values.git
   cd cluster-values

   BLUEPRINT=https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/root-extras/blueprints/semantic-router

   curl -fsSL "$BLUEPRINT/extraApps.yaml" -o extra-apps-values.yaml

   mkdir -p extra-apps/semantic-router/manifests
   curl -fsSL "$BLUEPRINT/values.yaml" -o extra-apps/semantic-router/values.yaml
   curl -fsSL "$BLUEPRINT/manifests/gateway-routing.yaml" \
       -o extra-apps/semantic-router/manifests/gateway-routing.yaml
   curl -fsSL "$BLUEPRINT/manifests/dashboard-admin-externalsecret.yaml" \
       -o extra-apps/semantic-router/manifests/dashboard-admin-externalsecret.yaml
   for f in sr-gateway.yaml sr-gateway-config.yaml \
            sr-gateway-proxy-config.yaml sr-gateway-service.yaml \
            sr-gateway-extproc.yaml quota.yaml; do
     curl -fsSL "$BLUEPRINT/manifests/aigw-extras/$f" \
         -o "extra-apps/semantic-router/manifests/$f"
   done
   ```

   The `aigw-extras/` directory only exists in this blueprint's own source —
   ArgoCD reads a flat `manifests/` directory, so every file above lands in
   `extra-apps/semantic-router/manifests/` directly, no subdirectory.

   The `sr-gateway*.yaml` files stand up a dedicated Envoy data plane for the
   router — you don't edit them per deployment, just fetch them as-is (see
   "Routing traffic through the router" for why a dedicated gateway exists at
   all). `quota.yaml` is optional — delete it if you don't want per-API-key
   token quotas, or leave it and fill in its `TODO`s alongside
   `gateway-routing.yaml`'s (see "Quota").

   Adjust the clone URL if your overlay repo isn't at the bootstrap default
   (`cluster-org/cluster-values` on the cluster's Gitea).

   The first `curl` overwrites `extra-apps-values.yaml`, which is what you want
   on a cluster that has no extra components yet — bootstrap seeds that file as
   an empty `extraApps: {}`. **If you already run other extras, don't overwrite
   it**: download `extraApps.yaml` somewhere else and add its `semantic-router:`
   block under your existing `extraApps:` key by hand. `extraApps` is a map, so
   entries just sit side by side.

   The `semantic-router:` key sets the Application name. The values path is
   fixed at `extra-apps/semantic-router/values.yaml`; changing the key does not
   change this path.

   Don't skip the `manifests/` file. The envelope has a source pointing at that
   directory, and ArgoCD fails an Application whose source path doesn't exist —
   so a missing `manifests/` takes the chart down with it, rather than just
   leaving the routing unconfigured. If you don't want the router in the request
   path, delete that source from the envelope instead of leaving it dangling.

3. Edit the `TODO`s in both files — dashboard hostname, model name and vLLM
   backend endpoint in `values.yaml`; the router's own hostname and the backend
   Services to route to in `gateway-routing.yaml`. The model names have to agree
   across the two files. List what's left to fill in with:

   ```bash
   grep -rn TODO extra-apps-values.yaml extra-apps/semantic-router
   ```

   The two hostname TODOs are deliberately different subdomains, not the same
   value copy-pasted twice: `values.yaml`'s is the dashboard
   (`sr-dashboard.<domain>`), `gateway-routing.yaml`'s is the router's own
   request path (`sr.<domain>`). Giving them the same hostname puts the
   dashboard and the router's `HTTPRoute` in conflict over one hostname.

   A `TODO` left in `gateway-routing.yaml` is not a legal Kubernetes name, so the
   sync fails and names the field. That's deliberate — better than a route that
   applies cleanly and points at nothing.

   `sr.<domain>` requires a client API key. Create the key Secret before
   sending requests. See "Reaching the router" below.

4. Review and push:

   ```bash
   git add extra-apps-values.yaml extra-apps/semantic-router
   git diff --cached
   git commit -m "Add semantic-router extra app"
   git push
   ```

   ArgoCD syncs `cluster-forge-extras`, which renders a `semantic-router`
   Application. Watch it with:

   ```bash
   kubectl get application semantic-router -n argocd -w
   ```

   Once it's `Synced`/`Healthy`, confirm the router itself is up before trusting
   any routing decisions:

   ```bash
   kubectl -n semantic-router port-forward svc/semantic-router 8080:8080
   curl localhost:8080/health
   ```

Once fetched, these files are yours. They are plain copies, not a live
reference, so nothing changed here later will alter your deployment.

## Routing decisions: choosing which model gets a request

The `values.yaml` above ships with exactly one `decisions` entry — a
catch-all that sends every request to the one model you configured. That's
the minimum to get something running, not the point of deploying a router:
semantic-router's job is choosing between *multiple* models based on the
request itself.

Worked examples of multi-model routing live in `examples/`, one file per
signal type:

| File | Routes by |
|---|---|
| `examples/complexity-routing-example.md` | prompt complexity — simple factual queries vs. reasoning/code-heavy ones |

Each example is self-contained: what the signal does, the full `values.yaml`
block, and how to verify which model a given request actually landed on.

## Routing traffic through the router

`manifests/gateway-routing.yaml` is what makes the router do its job. Without it
you have a classifier nobody consults.

The router is not a proxy. It runs as an Envoy external processor. Envoy sends
the request body to the router over gRPC. The router returns a model name, and
Envoy routes the request to that model's backend.

The request crosses two gateways. The shared `https` Gateway terminates TLS and
forwards traffic to dedicated `sr-gateway`. This internal Gateway runs the
router's ext_proc, model routing and API-key policy. An optional outer AI
Gateway can enforce one quota on the initial virtual model before routing. Keep
inner authentication enabled until direct access to `sr-gateway` is restricted.
Otherwise, callers can bypass the outer quota.

| Object | File | Does |
|---|---|---|
| `HTTPRoute` (`semantic-router-gateway`) | `gateway-routing.yaml` | claims `sr.<domain>` on the shared `https` Gateway, one catch-all rule forwarding to `sr-gateway` |
| `Gateway` (`sr-gateway`) | `sr-gateway.yaml` | this blueprint's own single-route Envoy data plane, HTTP only |
| `GatewayConfig`, `EnvoyProxy` | `sr-gateway-config.yaml`, `sr-gateway-proxy-config.yaml` | `sr-gateway`'s own copies of the cluster's ext_proc and Envoy tuning — `GatewayConfig`/`EnvoyProxy` are namespace-scoped, so the cluster's own can't be reused across namespaces |
| `Service` (`sr-gateway`) | `sr-gateway-service.yaml` | ClusterIP fronting `sr-gateway`'s Envoy pods — what the outer `HTTPRoute` actually forwards to |
| `EnvoyExtensionPolicy` (`sr-gateway-extproc`) | `sr-gateway-extproc.yaml` | calls the router on `50051`, plus metric-hygiene Lua |
| `AIGatewayRoute` (`semantic-router`) | `gateway-routing.yaml` | matches `x-selected-model`, one rule per model, on `sr-gateway` |
| `AIServiceBackend`, `Backend` | `gateway-routing.yaml` | one pair per model, the actual vLLM endpoint |
| `SecurityPolicy` (`semantic-router-apikey`) | `gateway-routing.yaml` | requires an API key and forwards the Secret key name as `x-api-key-id` |
| `QuotaPolicy` (optional) | `quota.yaml` | per-API-key token budget, see "Quota" |

The dedicated Gateway keeps policy scope clear. `SecurityPolicy` cannot target
an `AIGatewayRoute`. It targets `sr-gateway`, which serves only this router.

Keep the catch-all rule last. Envoy needs a matching rule before it calls an
external processor. Without the catch-all, Envoy returns 404 before the router
runs. Rules without matches also shadow later model rules, so put catch-all last.

The AIGatewayRoute catch-all handles unknown model names and requests where the
router does not select a model. The direct-Envoy fallback uses `failOpen: false`:
requests fail if the router is unavailable. This prevents clients from selecting
models with a forged `x-selected-model` header during an outage. The AI Gateway
path strips that header before the router runs.

Re-routing uses the chart's `clear_route_cache: true` default. Envoy then
matches again after semantic-router sets `x-selected-model`. Do not set this
default to `false`; requests would use the catch-all backend.
**The model list appears in both files, and that is not redundancy you can
remove.** The router emits a model name, not a backend address. `values.yaml` lists the
models it can select. `gateway-routing.yaml` maps each name to an
`AIServiceBackend` and `Backend`. Add a route rule for each model. Otherwise,
traffic uses the catch-all backend.


This blueprint creates a `Gateway`, `GatewayConfig` and `EnvoyProxy` in
`semantic-router`. It does not change the cluster's `ai-gateway`. Envoy Gateway
creates proxy pods in `envoy-gateway-system`; the manifests define a Service
and `ReferenceGrant` there.

On first deploy, confirm the AIGatewayRoute has an accepted route and requests
work. If the controller creates the route before its Gateway, it may not retry
after the Gateway appears. Change the AIGatewayRoute spec to trigger reconcile.

### Backends outside the cluster

Routing a model to OpenAI, Anthropic or any vLLM box on another network works,
and needs no core change. An `AIServiceBackend`'s `backendRef` can only name an
Envoy Gateway `Backend` (not a plain Service — a current upstream limitation,
[envoyproxy/ai-gateway#902](https://github.com/envoyproxy/ai-gateway/issues/902)),
so an external target is expressed as a `Backend` with an FQDN endpoint, paired
with an `AIServiceBackend` naming the provider's schema (`OpenAI`, `Anthropic`,
...). The Backend API is enabled on every bloomed cluster
(`extensionApis.enableBackend`), so it is available out of the box.
`gateway-routing.yaml` carries commented-out OpenAI and Anthropic examples.

Two things that are easy to miss:

- **An HTTPS provider needs a `BackendTLSPolicy` as well.** Without one Envoy
  speaks plaintext to port 443 and every request fails. It is also what supplies
  the SNI name and verifies the provider's certificate.
- **`AIServiceBackend` translates API formats.** Set `schema.name` to `OpenAI`
  or `Anthropic`. Test external provider routing and TLS before production use.
- **The gateway does not inject an API key, but the router can.** Nothing in
  `gateway-routing.yaml` adds credentials, so a client-supplied `Authorization`
  header reaches the provider untouched. For a cluster-held key, give the
  endpoint an `api_key_env` in `values.yaml` and supply that variable from a
  Secret — the router then attaches the credential itself before Envoy makes the
  call. Prefer `api_key_env` over `api_key`: the latter puts the secret in a file
  committed to the overlay repo.

Custom OpenAI-compatible paths or auth headers are not covered by this example.
Check current `AIServiceBackend` and `Backend` support before using such a
provider.

### Anthropic Messages API upstreams

Supported. Mark the model with `api_format: anthropic` in `values.yaml` and the
router takes its Anthropic path: it rewrites `:path` to `/v1/messages`, adapts
the body, sets `anthropic-version`, attaches the credential, and still signals
the choice with `x-selected-model`. Pair it with an `AIServiceBackend` whose
`schema.name` is `Anthropic` and a `Backend` pointing at `api.anthropic.com`.

Requests arriving on `/v1/messages` are recognised as Anthropic by the router
on the way in too, so clients can speak either wire format.

Test mixed OpenAI and Anthropic backends before using them together. The router
and AI Gateway both transform requests; confirm both transformations work with
your provider versions.
## Reaching the router

The router's management and gRPC ports stay cluster-internal. Clients send
requests through the Gateway:

| Service | Port | Serves |
|---|---|---|
| `semantic-router` | 8080 | management API — `/health`, `/api/v1/routing/preview`, `/api/v1/diagnostics/classify/*` |
| `semantic-router` | 50051 | gRPC, the external processor port the gateway wiring uses |
| `semantic-router-metrics` | 9190 | Prometheus metrics |

Port 8080 is the management API, not a chat endpoint. The chart binds it to
`0.0.0.0` for dashboard and health access inside the cluster. It has no public
route. Use it for health checks and classification debugging:

```bash
kubectl -n semantic-router port-forward svc/semantic-router 8080:8080
curl localhost:8080/health
```

To see which model the router selects for a given prompt, without the gateway
or any backend, call the routing preview:

```bash
curl -sX POST localhost:8080/api/v1/routing/preview \
  -H 'Content-Type: application/json' \
  -d '{"text":"Write a Python function to implement a binary search tree"}'
```

The response fields `selected_model` and `decision_result.decision_name` show
the outcome. Use this check for the `signals` and `decisions` logic in
`values.yaml` before you test the full request path through `sr.<domain>`.

A classification-only check uses `/api/v1/diagnostics/classify/intent`. That
response uses `recommended_model` and `decision_result.decision_name`. The
older path `/api/v1/classify/intent` returns 404 on the current image.
`GET /api/v1` lists the routes that this process registers. The chart image
tag is `latest`, so confirm the path there when a newer image moves a route.

The chart's `ingress.enabled` flag emits a classic `Ingress`. Envoy Gateway
uses Gateway API resources, so leave this flag disabled.

If routing doesn't look right, check what the router itself decided:

```bash
kubectl -n semantic-router logs deploy/semantic-router -f
```

`SecurityPolicy` requires a bearer token and returns 401 when the key is
missing or invalid. It targets `sr-gateway`, because SecurityPolicy cannot target
an AIGatewayRoute. Do not add `authorization: {defaultAction: Deny}` without an
Allow rule; it would deny authenticated requests too. This policy is separate
from the cluster's `ai-gateway` policy.

Create the Secret directly on the cluster, not the overlay repo, before
sending any real traffic — until it exists, every request is refused:

```bash
kubectl -n semantic-router create secret generic semantic-router-client-keys \
  --from-literal=TODO-your-client-name="$(openssl rand -hex 32)"
```

The Secret key name becomes `x-api-key-id` and identifies the quota bucket.
Give each client a unique name. Do not reuse names; the new client would share
the old client's current quota usage.

Send the key as a bearer token:

```bash
curl https://sr.<domain>/... -H "Authorization: Bearer <secret>"
```

A missing or invalid token returns 401 before the request reaches the router.

## Quota

`manifests/aigw-extras/quota.yaml` is optional. It needs the
`envoy-ai-gateway-ratelimit` app and client Secret described above. Quota buckets
use `x-api-key-id`, set by `SecurityPolicy`.

The sample sets one limit for all clients on one model. See
`examples/quota-tiers-example.md` for per-model limits, client tiers, and an
optional outer quota for the router's initial virtual model. Each model quota
must match a route backend's `modelNameOverride`. A backend in `targetRefs` also
needs its own `perModelQuotas` entry. `serviceQuota` is not enforced by the
controller build tested for this blueprint.

### Installing `envoy-ai-gateway-ratelimit`

The `envoy-ai-gateway-ratelimit` app runs `envoyproxy/ratelimit` and bundled
Redis. The controller sends quota rules to this service over xDS. Without it,
quotas fail open and do not throttle requests.

This app is not enabled by default. Add it to your overlay's `values.yaml`:

```yaml
enabledApps:
  - envoy-ai-gateway-ratelimit
```

The default uses one Redis instance without persistence or HA. A pod restart
can lose the current window's counters. To use shared Redis, override this app's
values in the overlay:

```yaml
apps:
  envoy-ai-gateway-ratelimit:
    valuesObject:
      redis:
        enabled: false
        url: "your-redis-host:6379"
```

Its Service name and namespace (`envoy-ai-gateway-ratelimit.envoy-gateway-system`)
are hardcoded in the chart, not templated: the AI Gateway controller's
`--quotaRateLimitServiceAddr` default and the ratelimit binary's xDS node ID
both target that exact address. Don't rename this app in your overlay.

Set `modelName` to the `modelNameOverride` on the matching
`AIGatewayRoute` backendRef. Set a `limit` and `duration` for each key. Allowed
durations are `1s`, `1m`, `1h`, and `1d`.

Keep `shadowMode: true` while checking usage. Shadow mode counts requests but
does not deny them. Set it to `false` only after checking usage and limits.

If `envoy-ai-gateway-ratelimit` is unreachable, quotas fail open. Alert on
rate-limit service health; a missing 429 does not prove usage is under budget.
A 429 means the client's bucket exceeded its limit for the current duration.
The bucket resets at the next window. Change limits in `quota.yaml` and sync.
Token enforcement depends on the AI Gateway build. The stock build used when
this blueprint was written counted requests, not tokens, for Distinct client
buckets. PR #2664 fixes this and merged upstream, but no release includes the
fix yet. A cluster-local test image passed live checks. Do not enforce token
limits until your controller and ext_proc include the fix. Quotas also fail open
if the rate-limit service is unavailable. A request admitted under its limit can
finish above it; the next request is denied.

## No AI Gateway? Direct-Envoy fallback

Everything above assumes the AI Gateway CRDs (`AIGatewayRoute`,
`AIServiceBackend`, `QuotaPolicy`) are on the cluster. If they are not,
`manifests/gateway-routing.yaml` will not deploy. Use
`manifests/gateway-routing-direct-envoy.yaml` instead — copy it in as
`gateway-routing.yaml`, not alongside the AI Gateway version, and drop
`manifests/aigw-extras/quota.yaml` and `manifests/aigw-extras/sr-gateway*.yaml`, none of which apply.

This fallback has no AI Gateway token quota or per-model schema translation.
External providers need a `URLRewrite` filter. API-key authentication remains
mandatory. It fails closed when semantic-router is unavailable, so callers
cannot use `x-selected-model` to choose a backend during router outage.

Treat this as the reduced-features fallback, not an equal alternative — pick
it only when the AI Gateway CRDs are genuinely unavailable.

## Timeouts, retries, and failover

Every HTTPRoute and AIGatewayRoute rule sets request and backend request
timeouts to `300s`. This covers classification and completion. Gateway API's
request timeout default is 15s. The ext_proc message timeout default is 200ms.
Raise both route timeouts and `messageTimeout` if completions can exceed 300s.

Retry and multi-backend failover examples are commented out in
`gateway-routing.yaml`:

- **Retry** can replay requests only before Envoy sends response bytes. The
  example retries connection failures, not generic 5xx or timeouts. Confirm that
  `BackendTrafficPolicy` attaches to AIGatewayRoute before enabling it.
- **Failover** needs health checks or outlier detection. Backend weights only
  split traffic; they do not remove unhealthy backends. Replicas behind one
  Service are already load-balanced.

## Storage

Upstream defaults `persistence.storageClassName` to `"standard"`, which our
clusters don't have. The blueprint sets it to `""`, which omits the field so the
cluster's default StorageClass applies.

Note `"-"` is *not* the way to say "use the default" — the chart translates it
into an explicit `storageClassName: ""`, meaning no class at all, and the PVC
stays Pending forever. If the cluster has no default class, name a real one.

## Dashboard access

The blueprint creates one dashboard admin at startup. OpenBao stores the
account. `manifests/dashboard-admin-externalsecret.yaml` copies it into Secret
`semantic-router-dashboard-admin` in the `semantic-router` namespace. The chart
reads that Secret. Fetch that manifest with the other blueprint files. An
overlay that already has an older copy of this blueprint must take the new
`values.yaml` and the new manifest.

| OpenBao path | Kind | Secret key | Value |
|---|---|---|---|
| `secrets/semantic-router-dashboard-admin-email` | static | `email` | `admin@<cluster domain>` |
| `secrets/semantic-router-dashboard-admin-name` | static | `name` | `admin` |
| `secrets/semantic-router-dashboard-admin-password` | random, write-once | `password` | login password |
| `secrets/semantic-router-dashboard-jwt-secret` | random, write-once | `jwt-secret` | session signing key |

`openbao-config` renders the email from the cluster domain. On a cluster whose
domain is `staging.silogen.ai`, the email is `admin@staging.silogen.ai`. The
display name is `admin`. Sign in with that email and the password from the
Secret:

```bash
kubectl -n semantic-router get secret semantic-router-dashboard-admin \
    -o jsonpath='{.data.password}' | base64 -d; echo
```

`dashboard.allowOpenBootstrap` is false. The public first-admin form stays
closed. The startup account does not use that form.

The dashboard writes the admin on startup only when that email is absent from
its database. An existing row for the same email keeps its password. A new
password in OpenBao does not replace it. Delete the dashboard volume, then let
the pod start again, when you need startup to create the account again.

A later change of the cluster domain updates the email in OpenBao. Static
OpenBao values follow the rendered value. The password and the signing key stay
at their first value. After the Secret refreshes and the dashboard pod starts
again, startup creates a second admin for the new email. The first admin
remains.

The ExternalSecret is an Argo CD PreSync hook. The Application waits for that
hook before it starts the dashboard pod. The pod reads the Secret at start.
The OpenBao secret manager writes the four values on its five-minute schedule.
On a cluster that is already up, the values exist before you install this
blueprint. Delete a Secret of this name that you created by hand, so the
ExternalSecret can create it.

Persistence is on in this blueprint. The admin, evaluation runs, and saved
workflows stay on the volume. With `dashboard.persistence.enabled: false`, that
data is on the container filesystem and is lost when the pod is recreated.
Startup creates the admin again on the next start, because the email is absent.

`dashboard.jwtSecret.existingSecret` points at the same Secret. A pod restart
keeps existing login sessions valid. Without that setting, the dashboard
generates a new signing key on every start, and every restart logs everyone
out.

## Updating

`targetRevision` in `extraApps.yaml` is pinned to a commit we've tested
end-to-end rather than tracking a branch, so an upstream push can't change your
cluster. To move to a newer version, bump it and re-check the chart's
`values.yaml` for renamed or added fields — this blueprint only overrides a
handful of them, and upstream's defaults supply the rest.
