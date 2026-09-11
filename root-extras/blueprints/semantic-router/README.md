# Blueprint: vLLM Semantic Router

[semantic-router](https://github.com/vllm-project/semantic-router) routes
incoming LLM requests to different backend models based on the content of the
request. This blueprint deploys the router plus its web dashboard, exposed
through the cluster's shared `https` Gateway, and puts the router in the request
path as an Envoy external processor so it actually decides where traffic goes.

Files fetched into your cluster-values overlay repo:

| File | Goes to | Contains |
|---|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml` | the ArgoCD Application envelope |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` | the chart config you edit |
| `manifests/gateway-routing.yaml` | `extra-apps/semantic-router/manifests/gateway-routing.yaml` | the routes and backends you edit |
| `manifests/sr-gateway*.yaml` | same directory | a dedicated Envoy data plane for the router — not edited per deployment, see "Routing traffic through the router" |
| `manifests/quota.yaml` | same directory | per-API-key token quota — optional, see "Quota" |

## Prerequisites

- Gateway API CRDs, the Envoy Gateway CRDs (`EnvoyExtensionPolicy`), the AI
  Gateway CRDs (`AIGatewayRoute`, `AIServiceBackend`, `QuotaPolicy`), and an
  `https` Gateway in `envoy-gateway-system` — all present on any bloomed cluster.
- A reachable vLLM backend serving the model you want to route to. The router
  deploys fine without one, it just has nothing to route to.
- A default StorageClass, or a real class name set in `values.yaml` (see below).
- **For token quota enforcement (`manifests/quota.yaml`) only:** the
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

2. Clone your cluster-values overlay repo from that Gitea and pull the three
   files into it:

   ```bash
   git clone https://gitea.<domain>/cluster-org/cluster-values.git
   cd cluster-values

   BLUEPRINT=https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/root-extras/blueprints/semantic-router

   curl -fsSL "$BLUEPRINT/extraApps.yaml" -o extra-apps-values.yaml

   mkdir -p extra-apps/semantic-router/manifests
   curl -fsSL "$BLUEPRINT/values.yaml" -o extra-apps/semantic-router/values.yaml
   for f in gateway-routing.yaml sr-gateway.yaml sr-gateway-config.yaml \
            sr-gateway-proxy-config.yaml sr-gateway-service.yaml \
            sr-gateway-extproc.yaml quota.yaml; do
     curl -fsSL "$BLUEPRINT/manifests/$f" \
         -o "extra-apps/semantic-router/manifests/$f"
   done
   ```

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

   Rename the `semantic-router:` key if you want a different Application name —
   nothing else depends on it. `extra-apps/semantic-router/values.yaml` is a
   literal path baked into the envelope's `valueFiles` entry, not derived from
   that key, so renaming it doesn't require touching the path.

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

   Unlike an earlier version of this blueprint, `sr.<domain>` is **not**
   reachable without a client API key — `gateway-routing.yaml`'s
   `SecurityPolicy` is mandatory, not optional, and everything not covered by
   its `apiKeyAuth` is refused by that same policy's default-deny backstop. You
   still have to create the key Secret before anything can call through; see
   "Reaching the router" below.

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

The router is not a proxy. It sits beside the request path as an Envoy external
processor: a request to `sr.<domain>` hits the shared `https` Gateway, Envoy asks
the router over gRPC which model should serve it, the router answers by setting a
header, and Envoy re-runs its route matching and forwards to that model's backend.

The request actually crosses two gateways. The shared `https` Gateway terminates
TLS for `sr.<domain>` and immediately hands off, unchanged, to a second,
dedicated `sr-gateway` that this blueprint stands up for itself — plain HTTP,
internal-only, one route. That second hop is where the router's ext_proc, the
model rule matching, the mandatory API key check, and (optionally) quota
enforcement all live.

| Object | File | Does |
|---|---|---|
| `HTTPRoute` (`semantic-router-gateway`) | `gateway-routing.yaml` | claims `sr.<domain>` on the shared `https` Gateway, one catch-all rule forwarding to `sr-gateway` |
| `Gateway` (`sr-gateway`) | `sr-gateway.yaml` | this blueprint's own single-route Envoy data plane, HTTP only |
| `GatewayConfig`, `EnvoyProxy` | `sr-gateway-config.yaml`, `sr-gateway-proxy-config.yaml` | `sr-gateway`'s own copies of the cluster's ext_proc and Envoy tuning — `GatewayConfig`/`EnvoyProxy` are namespace-scoped, so the cluster's own can't be reused across namespaces |
| `Service` (`sr-gateway`) | `sr-gateway-service.yaml` | ClusterIP fronting `sr-gateway`'s Envoy pods — what the outer `HTTPRoute` actually forwards to |
| `EnvoyExtensionPolicy` (`sr-gateway-extproc`) | `sr-gateway-extproc.yaml` | calls the router on `50051`, plus metric-hygiene Lua |
| `AIGatewayRoute` (`semantic-router`) | `gateway-routing.yaml` | matches `x-selected-model`, one rule per model, on `sr-gateway` |
| `AIServiceBackend`, `Backend` | `gateway-routing.yaml` | one pair per model, the actual vLLM endpoint |
| `SecurityPolicy` (`semantic-router-apikey`) | `gateway-routing.yaml` | mandatory, targets the `Gateway` — gateway-scoped default-deny backstop, overridden only by checking a bearer token against a Secret and forwarding the caller's identity as `x-api-key-id` |
| `QuotaPolicy` (optional) | `quota.yaml` | per-API-key token budget, see "Quota" |

Why a second gateway at all, rather than one `HTTPRoute` on the shared
`https` Gateway the way an earlier version of this blueprint did it: a
route-scoped `SecurityPolicy` on a Gateway that carries other apps' routes too
gets evaluated against Envoy's *pre-rerouted* first catch-all route — chosen by
route creation time, not by the model the request actually resolves to —
before the router's own re-route has taken effect. On a multi-route gateway
that can let a request through the wrong policy, or none. Giving the router a
Gateway that carries exactly one route removes the ambiguity: there is only
ever one catch-all, and it belongs to the one route this Gateway carries — the
outer `HTTPRoute` above.

CONFIRMED LIVE TEST (envoy-gateway v1.8.1): the mandatory `SecurityPolicy`
above targets the `Gateway`, not the `AIGatewayRoute` — SecurityPolicy's CRD
has a hard CEL validation rule restricting `targetRefs[*].kind` to
`Gateway`/`HTTPRoute`/`GRPCRoute`/`TCPRoute`, and rejects an `AIGatewayRoute`
targetRef outright, so a policy written against it can never apply. Targeting
the Gateway is safe here specifically because `sr-gateway` carries exactly one
route, per the paragraph above.

Two things about it are easy to get wrong later:

**The catch-all rule has to stay, and it goes last — in both the outer
`HTTPRoute` and the `AIGatewayRoute`.** An external processor only runs once a
route has already matched, so the request needs a rule that matches before the
router has said anything — which is every request on arrival, since
`x-selected-model` does not exist yet. Delete it and Envoy 404s everything
before the router is ever called. It goes last because a rule with no matches
would otherwise shadow the per-model rules. It is also where traffic lands
while the router is down, because the policy fails open — and, now, where a
request lands if the model name it's classified into has no matching rule,
since that model now arrives from an unvalidated request body rather than a
header this route itself set.

Re-routing also depends on the chart's `clear_route_cache: true` default —
that's what tells Envoy to re-match after the router sets the header. If
something overrides it to `false`, every request falls through to the
catch-all no matter what the router decided. Note this happens twice now:
once when AI Gateway's own built-in ext_proc derives a model from the request
body, and again when the router's ext_proc overrides that with its own
classification via `x-selected-model`. Whether the second re-route reliably
lands where the router intends has not been verified against a live cluster —
confirm it before relying on it in anything that matters.

**The model list appears in both files, and that is not redundancy you can
remove.** The router only ever emits a model *name* — its own reference Envoy
config puts it plainly: *"ExtProc only emits the x-selected-model routing signal;
Envoy owns endpoint load balancing."* It never names a backend address, so the
`AIGatewayRoute` has to already know a rule for every model the router may
pick. `values.yaml` tells the router which models it may choose between;
`gateway-routing.yaml` tells Envoy where each of those models actually lives —
now via an `AIServiceBackend`/`Backend` pair, not a plain `HTTPRoute` rule. Two
consumers, two lists, and a model missing from the second one silently lands on
the catch-all.

There is an ecosystem design that works the way you might expect — the processor
returns an `ip:port` and Envoy forwards there, via `x-gateway-destination-endpoint`
and an `ORIGINAL_DST` cluster. This router does not implement it at the pinned
commit (no such header exists in its `pkg/headers`), and Envoy Gateway cannot
express an `ORIGINAL_DST` cluster without `EnvoyPatchPolicy`, which is disabled
cluster-wide. Not an option here.

This blueprint's own gateway wiring touches nothing global — it stands up its
own `Gateway`, `GatewayConfig`, and `EnvoyProxy` in the `semantic-router`
namespace, alongside (not instead of) the cluster's own `ai-gateway` in
`envoy-gateway-system`. (The `sr-gateway` Service itself is CONFIRMED to live
in `envoy-gateway-system`, not `semantic-router` — see `sr-gateway-service.yaml`
— because that's where Envoy Gateway always creates the managed proxy pod it
selects, regardless of which namespace the `Gateway` object itself is in.)
Nothing here modifies `ai-gateway` or anything else in `envoy-gateway-system`.
Two cautions worth knowing about:

- Envoy AI Gateway has previously crashed outright when Gateway-labeled
  objects existed in more than one namespace at once — fixed upstream, and the
  fix is in the pinned commit this blueprint targets, but this exact
  multi-namespace shape (`sr-gateway` here, `ai-gateway` in
  `envoy-gateway-system`) has not been re-verified live. Watch the AI Gateway
  controller's logs after first deploy.
- CONFIRMED LIVE TEST: if the controller reconciles the `AIGatewayRoute` in
  `gateway-routing.yaml` before `sr-gateway.yaml`'s `Gateway` exists, it logs
  `"Gateway not found"` and — unlike the crash above — this does NOT self-heal:
  the route config for `sr-gateway` is left with zero `virtual_hosts`
  permanently, and every request 404s with an Envoy "NR" response flag. See the
  `AIGatewayRoute`'s comment in `gateway-routing.yaml` for the symptom check and
  fix (a genuine spec-level change to force a fresh reconcile).

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
- **`AIServiceBackend` translates the wire format for you — no `URLRewrite`
  needed.** Unlike the old plain-`HTTPRoute` design, you don't hand-rewrite the
  hostname or path: `schema.name: OpenAI`/`Anthropic` on the `AIServiceBackend`
  tells AI Gateway which upstream shape to speak, and it rewrites the request
  accordingly. This simplification follows from AI Gateway's own
  schema-translation design but hasn't been independently re-verified against a
  live external provider by this blueprint's own testing — a 401 from the
  provider (rather than a routing-level error) is still the sign the request
  really arrived.
- **The gateway does not inject an API key, but the router can.** Nothing in
  `gateway-routing.yaml` adds credentials, so a client-supplied `Authorization`
  header reaches the provider untouched. For a cluster-held key, give the
  endpoint an `api_key_env` in `values.yaml` and supply that variable from a
  Secret — the router then attaches the credential itself before Envoy makes the
  call. Prefer `api_key_env` over `api_key`: the latter puts the secret in a file
  committed to the overlay repo.

What this does not cover: a backend that keeps an OpenAI-shaped body but is
mounted under its own path with its own auth header (an internal LLM gateway,
an API-management layer, a hosted proxy that isn't literally OpenAI or
Anthropic). The old plain-`HTTPRoute` design handled that with
`URLRewrite`/`RequestHeaderModifier` filters on the route rule; there is no
confirmed equivalent under `AIServiceBackend`'s schema-translation model, since
its `backendRef` only names a `Backend` (an FQDN + port, no path/header
rewriting of its own) and a schema name from a fixed set. If you need this,
treat it as unsolved here rather than assuming it still works — check current
upstream `AIServiceBackend`/`Backend` capabilities before relying on it.

### Anthropic Messages API upstreams

Supported. Mark the model with `api_format: anthropic` in `values.yaml` and the
router takes its Anthropic path: it rewrites `:path` to `/v1/messages`, adapts
the body, sets `anthropic-version`, attaches the credential, and still signals
the choice with `x-selected-model`. Pair it with an `AIServiceBackend` whose
`schema.name` is `Anthropic` and a `Backend` pointing at `api.anthropic.com`.

Requests arriving on `/v1/messages` are recognised as Anthropic by the router
on the way in too, so clients can speak either wire format.

Worth being precise about what changed here: an earlier version of this
blueprint claimed nothing in this setup went through `ai-gateway`'s
`AIGatewayRoute` machinery, so a known gap in AI Gateway's own OpenAI→Anthropic
schema translator
([envoyproxy/ai-gateway#1936](https://github.com/envoyproxy/ai-gateway/issues/1936),
[#2127](https://github.com/envoyproxy/ai-gateway/pull/2127) — both still open)
didn't apply. That's no longer accurate — this blueprint now runs its own
`AIGatewayRoute` on its own dedicated `sr-gateway` (see "Routing traffic
through the router"), and mixing an `AIServiceBackend` whose `schema.name` is
`OpenAI` for one model with `Anthropic` for another, behind one
`AIGatewayRoute`, may exercise that same translation gap depending on how the
router's own body adaptation interacts with it. This has not been re-tested
against a live Anthropic backend under the new architecture — treat the
combination of "router does its own Anthropic adaptation" and "AIGatewayRoute
also does schema-aware routing" as unverified rather than assuming they compose
cleanly.

## Reaching the router

Only the dashboard gets a route of its own. The router's ports stay
cluster-internal — traffic reaches it through Envoy, not directly:

| Service | Port | Serves |
|---|---|---|
| `semantic-router` | 8080 | management API — `/api/v1/classify/*`, `/health` |
| `semantic-router` | 50051 | gRPC, the external processor port the gateway wiring uses |
| `semantic-router-metrics` | 9190 | Prometheus metrics |

Port 8080 is not a chat endpoint — route real requests through `sr.<domain>`
instead. Upstream binds it to `127.0.0.1`, which also blocks the dashboard (a
separate pod reaching it over the Service network). This blueprint widens the
bind to `0.0.0.0` via `VLLM_SR_MANAGEMENT_INTERNAL_LISTENER`, avoiding the
heavier `remote_exposure: true` + bearer-auth path. No Gateway route touches
8080, so external reachability is unchanged. Use it for health checks and
classification debugging:

```bash
kubectl -n semantic-router port-forward svc/semantic-router 8080:8080
curl localhost:8080/health
```

To see which model the router would pick for a given prompt, without needing
the gateway or any backend running yet, hit its classification endpoint
directly:

```bash
curl -sX POST localhost:8080/api/v1/classify/intent \
  -H 'Content-Type: application/json' \
  -d '{"text":"Write a Python function to implement a binary search tree"}'
```

The response's `recommended_model` and `decision_result.decision_name` show
the outcome — useful for checking `values.yaml`'s `signals`/`decisions` logic
in isolation before testing the full request path through `sr.<domain>`.

The chart's `ingress.enabled` flag is not useful on our clusters either — it
emits a classic `Ingress`, and Envoy Gateway only reconciles Gateway API
resources.

If routing doesn't look right, check what the router itself decided:

```bash
kubectl -n semantic-router logs deploy/semantic-router -f
```

Unlike an earlier version of this blueprint, `sr.<domain>` does **not** have
authentication left up to you: `gateway-routing.yaml`'s `SecurityPolicy`
(`semantic-router-apikey`) is mandatory, targets the `sr-gateway` `Gateway`
itself (CONFIRMED LIVE TEST: SecurityPolicy's CEL validation rejects an
`AIGatewayRoute` targetRef outright, so it cannot target that object instead —
see "Routing traffic through the router"), and gates every request behind a
bearer token checked against a Secret via `apiKeyAuth` — a request without a
valid key gets a 401 from that filter directly, before reaching the router or
backend. Unlike `ai.<domain>`, this never touches the cluster's own
`ai-gateway` auth chain — the two are entirely separate, and nothing in this
blueprint modifies `ai-gateway`.

CONFIRMED LIVE TEST (envoy-gateway v1.8.1): do not add an `authorization:`
block to this `SecurityPolicy` expecting it to "back up" apiKeyAuth — Envoy
Gateway's RBAC authorization layer is independent of apiKeyAuth, and a
successful apiKeyAuth authentication does not generate any RBAC allow rule.
`authorization: {defaultAction: Deny}` with no `rules` denies literally every
request, authenticated or not (confirmed via Envoy's `/config_dump`: the
compiled per-route RBAC policy had zero match branches, only an
`on_no_match: DENY` fallback). apiKeyAuth alone is sufficient for "mandatory
key, no keyless path"; only add an `authorization` block with explicit
`rules` if you want a second, independent allow-list layer (e.g.
`principal.headers` matching `x-api-key-id` against specific onboarded client
IDs) — and note that list has to be maintained here too, it is not implied by
the Secret.

Create the Secret directly on the cluster, not the overlay repo, before
sending any real traffic — until it exists, every request is refused:

```bash
kubectl -n semantic-router create secret generic semantic-router-client-keys \
  --from-literal=TODO-your-client-name="$(openssl rand -hex 32)"
```

The key **name** matters, not just its value: it's forwarded downstream as
`x-api-key-id` and is what `quota.yaml` (if you're using it) buckets spend
against. Reusing a name for a different tenant hands them whatever quota spend
the old tenant already accumulated in the current window — give each real
client its own key name, and don't recycle one.

Clients send the key as a bearer token:

```bash
curl https://sr.<domain>/... -H "Authorization: Bearer <the secret value>"
```

A mismatched or missing token is a 401 before the request reaches the router
or any backend.

## Quota

`manifests/quota.yaml` is optional — delete it if you don't want per-API-key
token budgets. If you keep it, it needs the `envoy-ai-gateway-ratelimit` app
(see "Prerequisites") and the Secret from "Reaching the router" above, since
quota buckets key on the same `x-api-key-id` the API-key policy forwards.

`quota.yaml` ships with exactly one `perModelQuotas` entry and one
`bucketRule` — the same limit for every key, on one model. For a separate
budget per model, or a higher limit for one named client without raising it
for everyone else, see `examples/quota-tiers-example.md`. That example also
covers two multi-model gotchas confirmed live on this blueprint: every
`AIServiceBackend` in `targetRefs` needs its own `perModelQuotas` entry (a
backend without one bleeds into another model's bucket instead of going
unmetered), and the CRD's `serviceQuota` field for a combined/router-wide
budget is inert on this controller build — don't configure it.

### Installing `envoy-ai-gateway-ratelimit`

`quota.yaml`'s actual enforcement backend: the generic `envoyproxy/ratelimit`
binary plus a bundled single-instance Redis, both defined in
`sources/envoy-ai-gateway-ratelimit/0.1.0` in this repo. `QuotaPolicy`'s
`bucketRules` are config the AI Gateway controller pushes to this service over
xDS — without it running, there's nothing to check or charge counters
against, which is why a missing install fails open instead of erroring.

Not in any `values_small/medium/large.yaml` `enabledApps` list — declared in
core `root/values.yaml` but deliberately left disabled by default (see
`docs/values_inheritance_pattern.md`'s "Optional Apps" section in the main
cluster-forge repo for this pattern in general). Add it to your own overlay's
`values.yaml`:

```yaml
enabledApps:
  - envoy-ai-gateway-ratelimit
```

That's enough for the default: bundled Redis, no persistence, no HA — a pod
restart loses at most one window's counters, the same exposure the
controller's fail-open default (`quotaRateLimitFailureModeDeny: false`)
already accepts. To point at a shared/HA Redis instead, override this app's
`valuesObject` in the same overlay:

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

Fill in its `TODO`s: which `AIServiceBackend` to target, the `modelName` (must
match the corresponding `AIGatewayRoute` rule's `x-selected-model` value, not
the backend's own name), and a `limit`/`duration` per key (`duration` accepts
only `1s`, `1m`, `1h`, or `1d`).

Ship with `shadowMode: true` on every `bucketRule`. In shadow mode every
request is still counted against its bucket — so you can watch real spend
accumulate against the limit you set before anyone is actually throttled — but
nothing is ever denied. Flip a rule's `shadowMode` to `false` only once you've
watched real usage against the real limit look right.

Two things worth knowing before you rely on this:

- **It fails open.** If `envoy-ai-gateway-ratelimit` is unreachable, requests
  are not blocked and not throttled — they just succeed, unmetered. A missing
  429 does not mean you're under budget; it can also mean the ratelimit
  service is down. Treat that as something to alert on, not something a 429
  will tell you about.
- **What a 429 means once `shadowMode` is off:** the caller's `x-api-key-id`
  bucket has exceeded its `limit` for the current `duration` window. It clears
  automatically at the next window boundary — there's nothing to reset by
  hand. To raise it, edit `quota.yaml` and let it sync — either the shared
  `Distinct` rule everyone falls under, or, for one client only, an `Exact`
  override rule (see `examples/quota-tiers-example.md`); there's no separate
  per-key override file.

On the AI Gateway controller build this blueprint was written against, a known
upstream defect means `limit` currently behaves as a **request** count per
window per key, not a token budget — the counter charged with actual token
cost is a different, shared-across-all-keys counter that can never deny. Real
token spend is still measured and visible (in the access log and this policy's
own counters), just not enforced as a token limit yet. `quota.yaml`'s own
comments carry the full detail; confirm this is fixed upstream before trusting
`limit` as tokens rather than requests.

## Timeouts, retries, and failover

Every rule in `gateway-routing.yaml` (both the outer `HTTPRoute` and the
`AIGatewayRoute`) sets `timeouts.request` and `timeouts.backendRequest` to
`300s`, matching `sr-gateway-extproc.yaml`'s `messageTimeout`. This isn't
optional tuning — Envoy Gateway's own default (200ms) would silently cut off
every real completion, so a route with no `timeouts` block at all is broken
for anything but a health check. Raise it per rule if a model's expected
completion time genuinely exceeds 300s; there's no per-model templating here,
so edit that model's own rule directly. (This mirrors, but doesn't copy, the
synopsys cluster's AI-Gateway setup, which uses 600s for the same reason on
its own `AIGatewayRoute` — different number, same reason for existing at all.)

Retry and multi-backend failover are documented but **not enabled** —
commented-out examples sit at the end of `gateway-routing.yaml`, retargeted at
the `AIGatewayRoute` rather than a plain `HTTPRoute`:

- **Retry** (`BackendTrafficPolicy.spec.retry`) is safe to turn on: Envoy's
  HTTP retry only replays a request if no response has started yet, so it
  can't double-fire an in-flight generation or double-bill GPU time. The
  example restricts `retryOn` to connect-failure/refused-stream/
  reset-before-request only — deliberately not generic 5xx or timeout,
  since a slow-but-working completion should never be retried. Still an
  opt-in, not a default, since it's the first use of this field in this
  repo. Verified on Envoy Gateway v1.8.1 (against the old plain-`HTTPRoute`
  design): a connect failure retried twice as configured, and a backend killed
  after it had flushed response headers was not retried. It does nothing for a
  backend that is scaled to zero — see below. Not re-verified against
  `BackendTrafficPolicy` targeting an `AIGatewayRoute` specifically —
  `BackendTrafficPolicy` is documented against Gateway/HTTPRoute/GRPCRoute, and
  whether it attaches the same way to an `AIGatewayRoute` is unconfirmed.
- **Failover** is *not* what a weighted multi-`backendRef` example gives you.
  `AIGatewayRoute` rules natively support `backendRefs[].weight` across
  multiple `AIServiceBackend`s, splitting traffic across two genuinely
  separate deployments (a second region, a second cluster) — that part works
  as a load split, but a weight is not a health signal. Measured under the old
  plain-`HTTPRoute` design with a 90/10 split and the primary scaled to zero,
  90 of 100 requests returned 503, and enabling retry didn't change that (an
  empty cluster is "no healthy upstream", which matches none of the retry
  triggers). A primary that is up but refusing connections partly recovers via
  retry, and still failed 15 of 100. Real failover needs the backend ejected
  from rotation — `BackendTrafficPolicy`'s `healthCheck` or
  `outlierDetection`, neither of which this blueprint configures, and neither
  re-verified against `AIServiceBackend`/`AIGatewayRoute`. Extra replicas of
  one Deployment need none of this; they already load-balance via the
  Service/EDS.

## Storage

Upstream defaults `persistence.storageClassName` to `"standard"`, which our
clusters don't have. The blueprint sets it to `""`, which omits the field so the
cluster's default StorageClass applies.

Note `"-"` is *not* the way to say "use the default" — the chart translates it
into an explicit `storageClassName: ""`, meaning no class at all, and the PVC
stays Pending forever. If the cluster has no default class, name a real one.

## Dashboard access

The dashboard has no admin account as shipped, and no way to create one through
the UI. That's deliberate: the upstream bootstrap endpoint is public and
unauthenticated, so leaving it open means whoever loads the URL first becomes
admin. On a Gateway-exposed dashboard that's not a good default.

Without `dashboard.persistence.enabled: true` (on by default in this
blueprint's `values.yaml`), the admin account lives only in the pod's
ephemeral filesystem and is wiped by any pod recreation — confirmed by
testing: turning `allowOpenBootstrap` back off recreated the pod and deleted
the admin we'd just created, until persistence was turned on.

Pick one login option before you try to log in.

**Throwaway demo** — uncomment in `values.yaml`:

```yaml
dashboard:
  allowOpenBootstrap: true
```

Then create the admin through the web form. Turn it back off once the admin
exists — with persistence on, the account survives that.

**Anything longer-lived** — provision the admin at startup instead. First
create the Secret the env vars below reference, directly on the cluster —
**not** through the overlay repo, since that would put the plaintext password
in Git:

```bash
kubectl -n semantic-router create secret generic semantic-router-dashboard-admin \
  --from-literal=password="$(openssl rand -hex 16)"
```

Then add these to `values.yaml`. Adding them closes the bootstrap path
automatically:

```yaml
dashboard:
  extraEnv:
    - name: DASHBOARD_ADMIN_EMAIL
      value: admin@example.com
    - name: DASHBOARD_ADMIN_NAME
      value: admin
    - name: DASHBOARD_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: semantic-router-dashboard-admin
          key: password
```

The Secret has to exist in the `semantic-router` namespace before ArgoCD syncs
this, or the dashboard pod sits in `CreateContainerConfigError`.

Self-healing even without persistence, since the admin is recreated from the
env vars every startup — but persistence still matters for everything else the
dashboard tracks (evaluation runs, saved workflows).

Worth knowing that login sessions are signed with a key the dashboard
regenerates on every pod start, so any restart logs everyone out regardless of
persistence. Set `dashboard.jwtSecret.existingSecret` if that matters.

## Updating

`targetRevision` in `extraApps.yaml` is pinned to a commit we've tested
end-to-end rather than tracking a branch, so an upstream push can't change your
cluster. To move to a newer version, bump it and re-check the chart's
`values.yaml` for renamed or added fields — this blueprint only overrides a
handful of them, and upstream's defaults supply the rest.
