# Example: per-model quotas and a per-client tier override

The blueprint's `quota.yaml` ships with exactly one `perModelQuotas` entry (one
model) and one `bucketRule` (`type: Distinct` on `x-api-key-id`) — every API
key gets the same limit, bucketed independently. This example shows the two
extensions that are commonly needed on top of that: a separate budget **per
model**, and a higher limit for **one named client** without raising the limit
for everyone else.

This replaces `quota.yaml`; do not append it as a partial block. Set each
backendRef's `modelNameOverride` to the model name that backend accepts. Use the
same value in `perModelQuotas[].modelName`. This example uses router model names
as backend model names; change both fields if your backend uses other names.

For example, add an override to each model rule in `gateway-routing.yaml`:

```yaml
rules:
  - matches:
      - headers:
          - name: x-selected-model
            value: TODO-simple-model
    backendRefs:
      - name: TODO-simple-model-backend
        modelNameOverride: TODO-simple-backend-model
    timeouts:
      request: 300s
      backendRequest: 300s
```

Set that quota entry's `modelName` to `TODO-simple-backend-model`, not the
`x-selected-model` value, unless both names are identical.

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
    # Match modelName to the corresponding BackendRef.modelNameOverride.
    - modelName: TODO-simple-backend-model
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
    - modelName: TODO-complex-backend-model
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

The order has been verified on a live test build: the Exact rule's limit
applied, while a different key used the Distinct rule. Keep Exact before
Distinct. Test your deployed controller in shadow mode before enforcing tiers.

## Add quota entries for each backend

Add each metered `AIServiceBackend` to `targetRefs` and add a matching
`perModelQuotas` entry. Match its `modelName` to the route's
`modelNameOverride`. Do not assume an omitted entry is unmetered; test your
controller's behavior before relying on that.
## One budget across routed models

`serviceQuota` is not enforced by the controller build tested for this
blueprint. To share one budget across models selected by semantic-router, add an
outer AI Gateway before the existing `sr-gateway`:

```yaml
# Optional outer route: meter initial model before inner semantic-router.
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: router-quota
  namespace: semantic-router
spec:
  parentRefs:
    - name: router-quota-gateway
  llmRequestCosts:
    - metadataKey: llm_total_token
      type: TotalToken
  rules:
    - backendRefs:
        - name: router-quota-backend
          modelNameOverride: auto
      timeouts:
        request: 300s
        backendRequest: 300s
---
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: QuotaPolicy
metadata:
  name: router-quota
  namespace: semantic-router
spec:
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: router-quota-backend
  perModelQuotas:
    - modelName: auto
      quota:
        mode: Shared
        bucketRules:
          - shadowMode: true
            clientSelectors:
              - headers:
                  - name: x-api-key-id
                    type: Distinct
            quota:
              limit: TODO
              duration: 1h
```

Define `router-quota-backend` as an OpenAI `AIServiceBackend` backed by an
Envoy Gateway `Backend` for the inner `sr-gateway` Service. Add a separate
outer Gateway, proxy Service, ReferenceGrant and public HTTPRoute. Add an outer
SecurityPolicy that sets `x-api-key-id`. Keep its `sanitize: false` so the
inner Gateway can authenticate the same key. Keep inner auth enabled until
network policy restricts direct access to the inner Gateway. Direct callers of
inner Gateway or vLLM backends bypass this outer quota.

Live test confirmed catch-all `modelNameOverride: auto` rewrites explicit and
missing model values. Semantic-router then selected either backend, while both
requests charged the same `auto` bucket. PR #2664 fixes Distinct token charging;
it is merged but not in a release yet. The live test used a test image. Keep
shadow mode until deployed controller and ext_proc include the fix.

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
