# Blueprint: vLLM Semantic Router

[semantic-router](https://github.com/vllm-project/semantic-router) routes
incoming LLM requests to different backend models based on the content of the
request. This blueprint deploys the router plus its web dashboard, exposed
through the cluster's shared `https` Gateway, and puts the router in the request
path as an Envoy external processor so it actually decides where traffic goes.

Three files to copy, all into your cluster-values overlay repo:

| File | Goes to | Contains |
|---|---|---|
| `extraApps.yaml` | `extra-apps-values.yaml` (merge the `semantic-router:` block under the existing `extraApps:` key) | the ArgoCD Application envelope |
| `values.yaml` | `extra-apps/semantic-router/values.yaml` | the chart config you edit |
| `manifests/gateway-routing.yaml` | `extra-apps/semantic-router/manifests/gateway-routing.yaml` | the gateway wiring you edit |

## Prerequisites

- Gateway API CRDs, the Envoy Gateway CRDs (`EnvoyExtensionPolicy`) and an
  `https` Gateway in `envoy-gateway-system` — all present on any bloomed cluster.
- A reachable vLLM backend serving the model you want to route to. The router
  deploys fine without one, it just has nothing to route to.
- A default StorageClass, or a real class name set in `values.yaml` (see below).

## Taking it into use

1. Copy the `semantic-router:` block from `extraApps.yaml` into your overlay
   repo's `extra-apps-values.yaml`, under the existing `extraApps:` key. Rename
   the key if you want a different Application name — nothing else depends on it.

2. Copy `values.yaml` to `extra-apps/semantic-router/values.yaml` in that same
   repo. The directory won't exist yet (bootstrap only seeds
   `extra-apps-values.yaml`); Gitea creates intermediate directories when you
   push, so just add the file at that path.

   If you renamed the key in step 1, keep the two in sync: the envelope's
   `valueFiles` entry is what points at this path.

3. Copy `manifests/gateway-routing.yaml` to
   `extra-apps/semantic-router/manifests/gateway-routing.yaml` in the same repo.

   Don't skip this one. The envelope has a source pointing at that directory, and
   ArgoCD fails an Application whose source path doesn't exist — so a missing
   `manifests/` takes the chart down with it, rather than just leaving the
   routing unconfigured. If you don't want the router in the request path, delete
   that source from the envelope instead of leaving it dangling.

4. Edit the `TODO`s in both files — dashboard hostname, model name and vLLM
   backend endpoint in `values.yaml`; the router's own hostname and the backend
   Services to route to in `gateway-routing.yaml`. `grep -r TODO` finds all of
   them. The model names have to agree across the two files.

   The two hostname TODOs are deliberately different subdomains, not the same
   value copy-pasted twice: `values.yaml`'s is the dashboard
   (`sr-dashboard.<domain>`), `gateway-routing.yaml`'s is the router's own
   request path (`sr.<domain>`). Giving them the same hostname puts the
   dashboard and the router's `HTTPRoute` in conflict over one hostname.

   A `TODO` left in `gateway-routing.yaml` is not a legal Kubernetes name, so the
   sync fails and names the field. That's deliberate — better than a route that
   applies cleanly and points at nothing.

5. Commit. ArgoCD syncs `cluster-forge-extras`, which renders a `semantic-router`
   Application. Watch it with:

   ```bash
   kubectl get application semantic-router -n argocd -w
   ```

Once copied, these files are yours. They don't track this repo, so nothing here
will change your deployment later.

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

### Verified

This wiring has been exercised end-to-end on a live cluster: an in-cluster
dummy backend plus real external OpenAI and Anthropic backends (deliberately
invalid keys, to prove reachability rather than a successful completion).
Across every test request, the decision the router logged matched the backend
that actually served it, confirming the whole chain:

- **The re-routing depends on the router setting `clear_route_cache` in its
  ext_proc response** — confirmed load-bearing. That is what tells Envoy to
  match the route again with the new header, and there is no gateway-side
  setting for it. The chart enables it (`clear_route_cache: true`); if someone
  overrides it to `false`, every request lands on the catch-all no matter what
  the router picked, and the rule-per-model design stops working entirely.
- **The header is `x-selected-model`.** Confirmed against the gateway's access
  log. Not `x-ai-eg-model` — that one belongs to the cluster's AI gateway and
  this router does not emit it.
- **Only the request path is processed**, which is all routing needs. See the
  comment in `gateway-routing.yaml` for why enabling the response path costs
  you token streaming — not exercised by this test, since neither the dummy nor
  the external backends touch the router's response-side features (semantic
  cache, token accounting).
- **`messageTimeout: 300s`** — no timeouts observed on any test request. It
  matches upstream's own Envoy config and covers buffering the body plus
  running classification, so it is not the network-hop timeout its name
  suggests.

Check the router's own logs to see what it received and what it decided:

```bash
kubectl -n semantic-router logs deploy/semantic-router -f
```

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

The chart's `ingress.enabled` flag is not useful on our clusters either — it
emits a classic `Ingress`, and Envoy Gateway only reconciles Gateway API
resources.

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
