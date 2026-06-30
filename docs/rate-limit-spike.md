# Rate-limiting spike (RL-1) — runbook

Proves native, per-API-key request + generation-token enforcement on the AI gateway using
Envoy Gateway global/cost-based rate limiting backed by Redis. No proxy or upstream code.

## What this branch changes

| Change | File |
| --- | --- |
| Enable EG global rate-limit service, point it at in-cluster Redis | `root/values.yaml` → `config.envoyGateway.rateLimit.backend` |
| Ephemeral Redis (Deployment + Service, no persistence/HA) | `sources/envoy-gateway-config/templates/ratelimit-redis.yaml` |
| Per-key `BackendTrafficPolicy` (request + token-budget rules) | `sources/envoy-gateway-config/templates/backend-traffic-policy-ratelimit.yaml` |
| Toggles + policy params | `sources/envoy-gateway-config/values.yaml` → `rateLimit.*` |

Defaults: `rateLimit.enabled: true` (Redis + backend), `rateLimit.policy.enabled: false`
(no policy renders until we supply a real key). So deploying the branch readies the infra
and enforces nothing.

## Step 1 — deploy the branch

Deploy `spike/rate-limiting-poc` to app-dev. Then confirm the infra came up:

```bash
K="./kubectl --context app-dev-1 -n envoy-gateway-system"
$K get deploy ratelimit-redis                 # Redis up
$K get pods -l app.kubernetes.io/name=envoy-ratelimit -A   # EG ratelimit service up
$K logs deploy/envoy-gateway | grep -i ratelimit | tail    # connected to Redis, no errors
```

Expected: `ratelimit-redis` Ready 1/1, an `envoy-ratelimit` pod Running, EG logs show the
rate-limit backend healthy. **Inference traffic must be unaffected at this point** (no policy yet).

## Step 2 — verify filter ordering (the one real risk)

The rate-limit filter must run **after** ext_authz, or `x-api-key-id` is absent when limiting
runs. The ai-gateway EnvoyProxy already sets `lua before ext_authz`; confirm ext_authz precedes
ratelimit in the live config:

```bash
$K get envoyproxy ai-gateway-proxy-config -o yaml | grep -A6 filterOrder
# if needed, dump the proxy's HTTP filter chain to confirm ext_authz -> ratelimit order
```

## Step 3 — plug in a real key and enforce

Once we have a real API key on app-dev and the model it can reach, set its `x-api-key-id`
(= the key's username) and flip the policy on. Two options:

**A. Via GitOps (clean):** set in `cluster-values` and redeploy —
`rateLimit.policy.enabled=true`, `rateLimit.policy.apiKeyId=<id>`, optionally tune
`requests`/`tokens` and `targetRef`.

**B. Via kubectl (fast spike iteration):** render and apply directly —
```bash
helm template t sources/envoy-gateway-config --set domain=<domain> --set aiGateway.enabled=true \
  --set rateLimit.policy.enabled=true --set rateLimit.policy.apiKeyId=<id> \
  --show-only templates/backend-traffic-policy-ratelimit.yaml | $K apply -f -
```
(Default policy: 5 requests/min and 1000 output-tokens/min for that key, attached to the
`ai-gateway` Gateway.)

## Step 4 — prove enforcement

With a known-good `curl` against the model using that key:

1. **Request limit:** fire >5 calls in a minute → expect HTTP **429** after the 5th.
2. **Token budget:** make calls that generate >1000 output tokens in a window → subsequent
   calls **429** once the budget is spent. Note the timing caveat: the budget is charged from
   the *previous* response's `llm_output_token`, so the request that crosses the line still
   succeeds (slight overshoot) and the next one is blocked.
3. **Isolation:** a *different* key keeps working while the limited key is throttled.
4. **Shared across replicas:** counts hold even when requests land on different Envoy pods
   (Redis is the shared store).

## Decisions to capture for RL-2 / RL-3

- Redis HA + persistence posture (this spike is ephemeral, in-memory).
- Windows to offer (min/hour/day).
- Confirm "generation tokens" = `llm_output_token` (vs total).
- Per-service limits → narrow `targetRef` from the Gateway to the per-service HTTPRoute, or
  add an `x-aim-service-id` clientSelector (header already present).
- Overshoot-by-one acceptable as the token-accounting model?

## Teardown

Set `rateLimit.enabled=false` (removes Redis + policy) and redeploy, or
`kubectl delete backendtrafficpolicy ratelimit-spike deploy/ratelimit-redis svc/ratelimit-redis`
plus revert the `root/values.yaml` backend block.
