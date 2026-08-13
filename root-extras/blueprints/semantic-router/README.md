# Blueprint: vLLM Semantic Router

[semantic-router](https://github.com/vllm-project/semantic-router) routes
incoming LLM requests to different backend models based on the content of the
request. This blueprint deploys the router plus its web dashboard, exposed
through the cluster's shared `https` Gateway, and puts the router in the request
path as an Envoy external processor so it actually decides where traffic goes.

Three files, all fetched into your cluster-values overlay repo:

| File | Goes to | Contains |
|---|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml` | the ArgoCD Application envelope |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` | the chart config you edit |
| `manifests/gateway-routing.yaml` | `extra-apps/semantic-router/manifests/gateway-routing.yaml` | the gateway wiring you edit |

## Prerequisites

- Gateway API CRDs, the Envoy Gateway CRDs (`EnvoyExtensionPolicy`) and an
  `https` Gateway in `envoy-gateway-system` — all present on any bloomed cluster.
- A reachable vLLM backend serving the model you want to route to. The router
  deploys fine without one, it just has nothing to route to.
- A default StorageClass, or a real class name set in `values.yaml` (see below).

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
   curl -fsSL "$BLUEPRINT/manifests/gateway-routing.yaml" \
       -o extra-apps/semantic-router/manifests/gateway-routing.yaml
   ```

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

   `sr.<domain>` has no authentication of its own by default — anyone who can
   reach the hostname can spend your GPU capacity. Decide now whether to gate
   it; see "Reaching the router" below for the annotation that requires a
   `cluster-auth` group.

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

Three objects, all in the `semantic-router` namespace except the last:

| Object | Does |
|---|---|
| `HTTPRoute` | claims `sr.<domain>` on the shared `https` Gateway, one rule per model |
| `EnvoyExtensionPolicy` | calls the router on `50051` for requests matching that route |
| `ReferenceGrant` | only if your vLLM backends live in another namespace |

Two things about it are easy to get wrong later:

**The catch-all rule has to stay, and it goes last.** An external processor only
runs once a route has already matched, so the request needs a rule that matches
before the router has said anything — which is every request on arrival, since
the header does not exist yet. Delete it and Envoy 404s everything before the
router is ever called. It goes last because a rule with no matches would
otherwise shadow the per-model rules. It is also where traffic lands while the
router is down, because the policy fails open.

Re-routing also depends on the chart's `clear_route_cache: true` default —
that's what tells Envoy to re-match after the router sets the header. If
something overrides it to `false`, every request falls through to the
catch-all no matter what the router decided.

**The model list appears in both files, and that is not redundancy you can
remove.** The router only ever emits a model *name* — its own reference Envoy
config puts it plainly: *"ExtProc only emits the x-selected-model routing signal;
Envoy owns endpoint load balancing."* It never names a backend address, so Envoy
has to already know a route for every model the router may pick. `values.yaml`
tells the router which models it may choose between; `gateway-routing.yaml` tells
Envoy where each of those models actually lives. Two consumers, two lists, and a
model missing from the second one silently lands on the catch-all.

There is an ecosystem design that works the way you might expect — the processor
returns an `ip:port` and Envoy forwards there, via `x-gateway-destination-endpoint`
and an `ORIGINAL_DST` cluster. This router does not implement it at the pinned
commit (no such header exists in its `pkg/headers`), and Envoy Gateway cannot
express an `ORIGINAL_DST` cluster without `EnvoyPatchPolicy`, which is disabled
cluster-wide. Not an option here.

**The policy targets the HTTPRoute, not a Gateway.** Envoy Gateway allows one
`EnvoyExtensionPolicy` per target and the cluster's `ai-gateway` already has one,
so a Gateway-scoped policy would mean standing up a second gateway and its own
routing objects. Targeting your own route needs none of that, touches nothing
global, and confines the blast radius to `sr.<domain>` — no other app's routes
and no `ai.<domain>` traffic. Nothing in this blueprint modifies `ai-gateway` or
anything else in `envoy-gateway-system`.

### Backends outside the cluster

Routing a model to OpenAI, Anthropic or any vLLM box on another network works,
and needs no core change. A Gateway API `backendRefs` entry can only name an
in-cluster Service, so an external target is expressed as an Envoy Gateway
`Backend` with an FQDN endpoint, which a rule then references by
`group: gateway.envoyproxy.io, kind: Backend`. The Backend API is enabled on
every bloomed cluster (`extensionApis.enableBackend`), so it is available out of
the box. `gateway-routing.yaml` carries commented-out OpenAI, Anthropic, and
non-standard-URL examples.

Two things that are easy to miss:

- **An HTTPS provider needs a `BackendTLSPolicy` as well.** Without one Envoy
  speaks plaintext to port 443 and every request fails. It is also what supplies
  the SNI name and verifies the provider's certificate.
- **The gateway does not inject an API key, but the router can.** Nothing in
  `gateway-routing.yaml` adds credentials, so a client-supplied `Authorization`
  header reaches the provider untouched. For a cluster-held key, give the
  endpoint an `api_key_env` in `values.yaml` and supply that variable from a
  Secret — the router then attaches the credential itself before Envoy makes the
  call. Prefer `api_key_env` over `api_key`: the latter puts the secret in a file
  committed to the overlay repo.

This is a smaller setup than a sidecar Envoy with hand-written config, because
the `Backend` CRD covers the one thing hand-written config was needed for. What
it does not cover is anything requiring raw xDS — an `ORIGINAL_DST` cluster, for
instance — since `EnvoyPatchPolicy` is not enabled on these clusters.

### A backend that isn't mounted at a standard URL

Not every OpenAI-compatible backend actually lives at `/v1/...` on its own
hostname. Internal LLM gateways, API-management layers, and hosted proxies
often keep an OpenAI-shaped request/response body but mount it under their own
path, and require a header of their own (a subscription key, a tenant ID,
whatever their auth scheme needs). None of that needs `AIGatewayRoute`'s
schema translation — the body is still OpenAI-shaped, only the URL and headers
differ, and that is squarely inside what Gateway API's own `HTTPRoute` filters
already do.

Say the real endpoint is `https://example.com/gateway/v1/chat/completions`
(note `/gateway/v1` instead of a bare `/v1`) and it needs an `X-API-Key` header
the client never sends. Reachable with the same `Backend`/`BackendTLSPolicy`
pair as the OpenAI/Anthropic examples above, plus two filters on the model's
rule in the `HTTPRoute`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: example-gateway
  namespace: semantic-router
spec:
  endpoints:
    - fqdn:
        hostname: example.com
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: example-gateway-tls
  namespace: semantic-router
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: example-gateway
  validation:
    wellKnownCACertificates: System
    hostname: example.com
```

Then the route rule itself. The path match has to be `/v1` specifically, not
the bare `/` used by the in-cluster rules elsewhere in this file, so that
`ReplacePrefixMatch` swaps out exactly the segment the client sent instead of
prepending onto it:

```yaml
    - matches:
        - headers:
            - name: x-selected-model
              value: example-model
          path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - group: gateway.envoyproxy.io
          kind: Backend
          name: example-gateway
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: example.com
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /gateway/v1
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-API-Key
                value: TODO-your-key
```

A request to `/v1/chat/completions` becomes `/gateway/v1/chat/completions` on
the wire to `example.com` — `PathPrefix: /v1` matches the segment the client
sent, and `ReplacePrefixMatch` substitutes it for `/gateway/v1` rather than
gluing the two together. Matching `/` instead of `/v1` here would produce
`/gateway/v1/v1/chat/completions`, which is wrong.

`URLRewrite` and `RequestHeaderModifier` are both core Gateway API filter
types, same status as the `headers` match above — no extra CRD instance to
create, they go inline in the rule.

This only covers URL and header differences. If the backend's request or
response *body* isn't OpenAI-shaped at all, `URLRewrite`/`RequestHeaderModifier`
can't help — see the Anthropic section below for how the router can own that
adaptation itself instead, or stand up a small translation shim as the real
`Backend` if the router has no built-in adapter for that provider's format.

### Anthropic Messages API upstreams

Supported, and the wiring above needs no change. Mark the model with
`api_format: anthropic` in `values.yaml` and the router takes its Anthropic path:
it rewrites `:path` to `/v1/messages`, adapts the body, sets `anthropic-version`,
attaches the credential, and still signals the choice with `x-selected-model`.
So the HTTPRoute rule for a Claude model looks exactly like one for a vLLM model,
just with a `Backend` pointing at `api.anthropic.com`.

Requests arriving on `/v1/messages` are recognised as Anthropic on the way in
too, so clients can speak either wire format.

Worth being precise about what this is not: the router adapts to an Anthropic
*upstream*, it is not Envoy AI Gateway's OpenAI→Anthropic schema translator.
That translator does not exist in a release yet
([envoyproxy/ai-gateway#1936](https://github.com/envoyproxy/ai-gateway/issues/1936),
[#2127](https://github.com/envoyproxy/ai-gateway/pull/2127) — both still open),
and it would only matter on an `AIGatewayRoute`, which this blueprint does not
use. Nothing here goes through `ai-gateway`, so its gap is not ours.

## Reaching the router

Only the dashboard gets a route of its own. The router's ports stay
cluster-internal — traffic reaches it through Envoy, not directly:

| Service | Port | Serves |
|---|---|---|
| `semantic-router` | 8080 | management API — `/api/v1/classify/*`, `/health` |
| `semantic-router` | 50051 | gRPC, the external processor port the gateway wiring uses |
| `semantic-router-metrics` | 9190 | Prometheus metrics |

Port 8080 is not a chat endpoint despite exposing an OpenAI-shaped path. Upstream
binds it to localhost with `remote_exposure: false`, and it is not meant to take
full completions. Route through `sr.<domain>` instead; use 8080 for health checks
and classification debugging:

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

One thing to be deliberate about: `sr.<domain>` has no authentication of its own,
so anyone who can reach the hostname can spend your GPU capacity. Unlike
`ai.<domain>`, it does not pass through the cluster's AI auth chain — that runs
on `ai-gateway`, which this blueprint deliberately leaves alone. Put an auth layer
in front of it before exposing it to anyone you would not hand a GPU to.

`cluster-auth`'s ext_authz already runs against every route on the shared
`https` Gateway, including this one — but its default policy set only requires
auth for `admin`-role callers, so `sr.<domain>` passes through unauthenticated
by default just like any other new route. To require a specific group, annotate
the `HTTPRoute` in `gateway-routing.yaml`:

```yaml
metadata:
  name: semantic-router
  namespace: semantic-router
  annotations:
    cluster-auth/allowed-group: <your-group>
```

That matches cluster-auth's `httproute-group-based-access` policy
(`requireAuth: true`), so only callers in `<your-group>` are let through; anyone
else gets rejected before the request reaches the router or the model backend.

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

Pick one before you try to log in.

**Throwaway demo** — uncomment in `values.yaml`:

```yaml
dashboard:
  allowOpenBootstrap: true
```

Then create the admin through the web form. Fine on a cluster you're about to
delete; don't leave it on otherwise.

**Anything longer-lived** — provision the admin at startup instead. Adding these
closes the bootstrap path automatically:

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

Worth knowing that login sessions are signed with a key the dashboard
regenerates on every pod start, so any restart logs everyone out. Set
`dashboard.jwtSecret.existingSecret` if that matters.

## Updating

`targetRevision` in `extraApps.yaml` is pinned to a commit we've tested
end-to-end rather than tracking a branch, so an upstream push can't change your
cluster. To move to a newer version, bump it and re-check the chart's
`values.yaml` for renamed or added fields — this blueprint only overrides a
handful of them, and upstream's defaults supply the rest.
