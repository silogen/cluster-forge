# Example: per-model quotas and a per-client tier override

The blueprint's `quota.yaml` ships with exactly one `perModelQuotas` entry (one
model) and one `bucketRule` (`type: Distinct` on `x-api-key-id`) — every API
key gets the same limit, bucketed independently. This example shows the two
extensions that are commonly needed on top of that: a separate budget **per
model**, and a higher limit for **one named client** without raising the limit
for everyone else.

This is config for `quota.yaml` itself — it replaces the entire file, not a
sub-block. It pairs naturally with `complexity-routing-example.md`: the two
models below reuse that example's `TODO-simple-model` / `TODO-complex-model`
names, on the assumption you're also routing between them by complexity. Swap
in your own model names if you're not.

## The config

```yaml
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: QuotaPolicy
metadata:
  name: semantic-router
  namespace: semantic-router
spec:
  targetRefs:
    # One entry per AIServiceBackend you want quota enforcement on — a plain
    # list, same shape as the blueprint's single-model targetRefs, just more
    # of them.
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: TODO-simple-model-backend
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: TODO-complex-model-backend
  perModelQuotas:
    # One block per model, each with its own independent bucketRules. A
    # client's simple-model spend and complex-model spend are tracked and
    # limited completely separately.
    - modelName: TODO-simple-model
      quota:
        mode: Shared
        bucketRules:
          # Named-client override MUST come before the Distinct catch-all
          # below — see "Rule order and precedence".
          - shadowMode: true
            clientSelectors:
              - headers:
                  - name: x-api-key-id
                    type: Exact
                    value: TODO-premium-client-name
            quota:
              limit: 500000
              duration: 1h
          - shadowMode: true
            clientSelectors:
              - headers:
                  - name: x-api-key-id
                    type: Distinct
            quota:
              limit: 50000
              duration: 1h
    - modelName: TODO-complex-model
      quota:
        mode: Shared
        bucketRules:
          - shadowMode: true
            clientSelectors:
              - headers:
                  - name: x-api-key-id
                    type: Exact
                    value: TODO-premium-client-name
            quota:
              limit: 100000
              duration: 1h
          - shadowMode: true
            clientSelectors:
              - headers:
                  - name: x-api-key-id
                    type: Distinct
            quota:
              limit: 5000
              duration: 1h
```

## Rule order and precedence

`type: Exact` (with a `value`) is a legal `clientSelectors` header match
alongside `Distinct` — the CRD's enum is `Exact | RegularExpression |
Distinct`, `quota.yaml`'s own comments just never mention the first two. A
named client's requests match the `Exact` rule above (its own literal
`x-api-key-id` value) **and** the `Distinct` rule (which matches any/all
values, including that one) at the same time.

The CRD's own doc for `bucketRules` says: *"If a request matches multiple
rules, each of their associated quotas get applied, so a single request might
burn down the quota for multiple rules... combined with the first limit taking
precedence."* Put together, that reads as: both buckets get charged, but the
*first* matching rule's limit is the one enforced for a deny decision — which
is why the `Exact` override is listed **before** the `Distinct` catch-all
above. List order is significant here, not just readability.

**UNVERIFIED against a live cluster**, unlike most of this blueprint's other
CRD-behavior claims: whether a named client actually gets the raised 500000/
100000 limit, or whether it's silently capped by also accumulating against the
Distinct bucket's lower 50000/5000 limit underneath, has not been confirmed
end-to-end the way the base `Distinct`-only setup in `quota.yaml` was. Before
relying on this for a real tier, watch both counters (see "Verifying it")
under real traffic from the premium key and confirm the higher limit is what
actually gates it.

## Every backend in `targetRefs` needs its own `perModelQuotas` entry

**Confirmed live**, unlike most of the caveats below: if an `AIServiceBackend`
is listed in `targetRefs` but has no matching `perModelQuotas` entry, its
traffic doesn't go unmetered — it bleeds into whichever `perModelQuotas`
entry the controller falls back to, charging *another model's* bucket
instead. Adding a third backend to `targetRefs` without also giving it its
own `modelName` entry above will silently corrupt that other model's quota
counters, not just leave the new backend unenforced. Always add both — the
`targetRefs` entry and its `perModelQuotas` entry — in the same change.

## There's no router-wide/combined quota — don't use `serviceQuota`

The CRD also has a top-level `spec.serviceQuota` field, advertised as "quota
for all models served by AIServiceBackend(s)... overridden for specific
models using perModelQuotas" — i.e. a single shared budget across every
model in `targetRefs`. **Confirmed live: it's inert on this controller
build.** No descriptor is ever emitted for it — zero tracking, zero
enforcement, not even in shadow mode — matching the CRD schema's own
disclosed caveat ("the rate limit configuration is properly set up, but the
descriptor set is not being set in the Envoy Configuration"). Configuring it
has no effect at all; don't rely on it.

There's currently no substitute, either: `perModelQuotas` buckets are
independent, not summed, so two models each capped at `limit` bound total
spend at `2 × limit`, not one shared `limit`. If you need a genuinely
combined cap across models, it isn't achievable with this controller build —
only N independent per-model caps.

## Verifying it

Send a request from the premium key and a request from any other key against
the same model, then watch what each accumulates:

```bash
curl https://sr.<domain>/v1/chat/completions \
  -H "Authorization: Bearer <premium client's key>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"TODO-simple-model","messages":[{"role":"user","content":"hello"}]}'

curl https://sr.<domain>/v1/chat/completions \
  -H "Authorization: Bearer <a regular client's key>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"TODO-simple-model","messages":[{"role":"user","content":"hello"}]}'
```

Both requests' `api_key_id` and token counts land in `sr-gateway`'s access log
(`sr-gateway-proxy-config.yaml`'s JSON format), so:

```bash
kubectl -n envoy-gateway-system logs deploy/sr-gateway -f
```

confirms which key each request was charged under. To see the actual bucket
values (needs `envoy-ai-gateway-ratelimit`'s bundled Redis, see the README's
"Installing `envoy-ai-gateway-ratelimit`"):

```bash
kubectl -n envoy-gateway-system exec deploy/envoy-ai-gateway-ratelimit-redis -- \
  redis-cli KEYS '*'
kubectl -n envoy-gateway-system exec deploy/envoy-ai-gateway-ratelimit-redis -- \
  redis-cli GET '<key printed above>'
```

Send enough requests from the premium key alone to exceed 50000 (the
`Distinct` catch-all's limit) but stay under 500000 (its own `Exact` limit),
with `shadowMode` flipped to `false` on both rules. If it keeps succeeding
past 50000, the `Exact` override's higher limit is what's actually gating it —
confirming the "first limit takes precedence" reading above. If it starts
getting `429`s at 50000 instead, the `Distinct` bucket is the one enforcing
despite being listed second, and this pattern doesn't work the way the CRD's
doc implies.

## What this doesn't show

- **`RegularExpression`** header matching (the third enum value alongside
  `Exact`/`Distinct`) — plausible for matching a naming convention across a
  set of clients (e.g. `TODO-.*-premium`) rather than listing each one, but
  untested here.
- **More than two tiers.** Nothing stops adding a third `bucketRule` (e.g. a
  mid tier) ahead of the `Distinct` catch-all — same order-matters caveat
  applies with more rules in play, and hasn't been tried with three.
