# Rate-limiting spike (RL-1) — runbook

Proves native, per-API-key request + generation-token enforcement on the AI gateway using
Envoy Gateway global/cost-based rate limiting backed by Redis. No proxy or upstream code.

## Results — GO (executed 2026-06-30 on app-dev, EG v1.7.1)

Per-API-key request **and** generation-token enforcement work end-to-end with zero code in
the auth/proxy path. The engine is essentially turnkey; what's left is the product layer.

**Evidence.** With a 5 req/min + 100 output-token/min policy keyed on a real key's
`x-api-key-id`, six back-to-back `Hello` calls produced:

```
200(55 tok) → 200(49 tok) → 429 → 429 → 429 → 200
```

- 55+49 = 104 output tokens spent the 100-token budget → requests 3–5 got **429**.
- Access log on `ai-gateway` showed `response_code=429, response_flags=RL` (Envoy rate-limited).
- Redis held two fixed-window buckets keyed per rule: request-count `=5`, token-count `=104`
  for the burst minute; a fresh bucket for the next minute (which let request 6 through).
- A 429 firing at all **confirms ext_authz runs before the rate-limit filter** — `x-api-key-id`
  was present at limiting time, so the documented ordering risk is a non-issue.

**Identifier — per-API-key works out of the box.** `x-api-key-id` is the OpenBao token
DisplayName, which AIWB mints as `token-<namespace>-<apikeyname>` (unique constraint on
`(display_name, namespace)`; namespaces globally unique). So the value is **globally unique
per API key** — the policy selector gives true per-key granularity with no cluster-auth change
and without keying on anything sensitive (the bearer token never touches the limit key).

**Deploy safety (observed).** Deploying the branch was inert: no policy renders by default,
and EG **auto-activated the rate-limit backend on the ConfigMap change without a controller
restart** (controller pod untouched). Inference stayed 200 throughout. Removing the test BTP
(applied via `kubectl`, not git) returned instantly to normal.

**Carry-forward findings (for RL-2…RL-7):**
1. **Fixed windows, not sliding** — counters reset on wall-clock boundaries; bursty at edges.
   Informs which windows RL-3 offers.
2. **Token overshoot-by-one** — the budget is charged *after* the response, so the request that
   crosses the line completes and the *next* one is blocked.
3. **Bare 429** — no informative body/headers today (`response_flags=RL` only) → RL-6 shaping.
4. **Fail-open only** — v1.7.1's `BackendTrafficPolicy` has no `failClosed` field, so a
   Redis/ratelimit outage cannot block model traffic. Accept, or revisit if a hard cap is needed.

The steps below are the original runbook, kept for reproducibility.

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
(the OpenBao DisplayName AIWB mints as `token-<namespace>-<apikeyname>` — globally unique per
key; harvest the exact value from the `ai-gateway` access log field `api_key_id`) and flip the
policy on. Two options:

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
