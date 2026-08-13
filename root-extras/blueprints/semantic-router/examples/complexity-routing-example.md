# Example: routing by prompt complexity

The blueprint's `values.yaml` ships with exactly one `decisions` entry — a
catch-all that sends every request to one model. This example replaces that
with two models and a real decision between them: simple, factual prompts go
to a small/cheap model; anything that looks like reasoning or code goes to a
bigger one.

This is config for the router itself (`config.routing` in `values.yaml`), not
the gateway. It decides which model a request gets; `gateway-routing.yaml`
still needs a rule per model so Envoy can reach whichever one the router
picks — see this blueprint's README, "The model list appears in both files".

The block below replaces the entire `config:` key in your copy of
`values.yaml` (`extra-apps/semantic-router/values.yaml` in your cluster-values
overlay repo) — leave `persistence:` and `dashboard:` as you already have
them.

## How the signal works

`complexity` is one of semantic-router's built-in signal types. Instead of a
regex or keyword list, you give it a handful of example prompts for each end
of the spectrum — `hard` candidates and `easy` candidates — and it embeds an
incoming request and measures which cluster of examples it's closer to,
against a similarity `threshold`. A decision then matches on
`task-complexity:hard` or `task-complexity:easy`.

## The config

Both vLLM backends need to already be up and reachable — this block defines
the two models and the decision logic between them, but it doesn't stand up
the model servers themselves. Substitute your own model names for
`TODO-simple-model` / `TODO-complex-model` throughout.

```yaml
config:
  providers:
    defaults:
      default_model: "TODO-simple-model"
    models:
      - name: "TODO-simple-model"
        provider_model_id: "TODO-simple-model"
        backend_refs:
          - name: "primary"
            endpoint: "TODO-simple-vllm-service:8000"
            protocol: "http"
            weight: 100
      - name: "TODO-complex-model"
        provider_model_id: "TODO-complex-model"
        backend_refs:
          - name: "primary"
            endpoint: "TODO-complex-vllm-service:8000"
            protocol: "http"
            weight: 100
  routing:
    signals:
      complexity:
        - name: task-complexity
          description: "Distinguish simple factual queries from complex reasoning tasks."
          threshold: 0.1
          hard:
            candidates:
              - "Write a Python function to implement a binary search tree"
              - "Explain trade-offs between consistency and availability in distributed systems"
          easy:
            candidates:
              - "What is the capital of France?"
              - "Summarize this paragraph"
    modelCards:
      - name: "TODO-simple-model"
      - name: "TODO-complex-model"
    decisions:
      - name: "hard-to-complex-model"
        description: "Complex/reasoning prompts route to the bigger model."
        priority: 200
        rules:
          operator: "AND"
          conditions:
            - type: "complexity"
              name: "task-complexity:hard"
        modelRefs:
          - model: "TODO-complex-model"
            use_reasoning: false
      - name: "easy-to-simple-model"
        description: "Simple factual prompts route to the smaller model."
        priority: 150
        rules:
          operator: "AND"
          conditions:
            - type: "complexity"
              name: "task-complexity:easy"
        modelRefs:
          - model: "TODO-simple-model"
            use_reasoning: false
      - name: "default-route"
        description: "Catch-all — anything that matches neither signal."
        priority: 100
        rules:
          operator: "AND"
          conditions: []
        modelRefs:
          - model: "TODO-simple-model"
            use_reasoning: false
```

Three things worth being deliberate about:

**Priority order, and the catch-all's place in it.** `decisions` are
evaluated highest-`priority`-first; the first one whose `conditions` match
wins. The catch-all keeps `conditions: []` — it matches unconditionally — so
it has to sit at the lowest priority (`100` here) or it would win before the
signal-based decisions ever got a chance. This is the same shape as the
mandatory catch-all *rule* in `gateway-routing.yaml`, just one layer up: there
it's Envoy's route-matching that needs a fallback, here it's the router's own
decision-matching.

**The `threshold` is a similarity cutoff, not a probability.** `0.1` above is
upstream's own example value, not a tuned recommendation — start there and
adjust based on what you see the router actually pick (see verification
below), rather than assuming it's calibrated for your traffic.

**`use_reasoning: false`** just means "don't ask this model to run in its own
extended-thinking / reasoning mode" — it's a per-model-ref switch on how the
request is sent, unrelated to the `complexity` signal above, which classifies
the *prompt*, not what the model itself should do with it.

## Verifying it

Send an obviously easy prompt and an obviously hard one, then check which
model each landed on:

```bash
curl -sk https://sr.<domain>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"TODO-simple-model","messages":[{"role":"user","content":"What is the capital of France?"}]}'

curl -sk https://sr.<domain>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"TODO-simple-model","messages":[{"role":"user","content":"Write a Python function to implement a binary search tree"}]}'
```

The `model` field in the request body is what the client thinks it's calling
— the router is free to override it. Check the router's own logs to see what
it actually decided and why:

```bash
kubectl -n semantic-router logs deploy/semantic-router -f
```

Backends not wired up yet? The router's own classification endpoint (see the
main README's "Reaching the router") checks the same `hard`/`easy` decision
logic directly, without needing `sr.<domain>` or any backend at all.

If both requests land on the same model, the two candidate sets are probably
too close together for the `threshold` you set — widen the gap between your
`hard`/`easy` candidates or lower the threshold.

## Other signal types

`complexity` is one signal type among several upstream supports (domain
classification and others). The shape is the same regardless — a
`signals.<type>` block feeding `conditions` in `decisions` — but this example
only covers `complexity`; it's the only one currently verified end-to-end
against a live cluster. Treat other signal types as unverified here until
someone runs them end-to-end and adds an example.
