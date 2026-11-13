# Example: routing by prompt complexity

The blueprint's `values.yaml` ships with exactly one `decisions` entry, under
`config.recipes`. It is a catch-all that sends every request to one model.
This example replaces that recipe with two models and a decision between them:
a `hard` label selects the larger model, an `easy` label selects the smaller
one.

This is config for the router itself (`config.recipes` in `values.yaml`), not
the gateway. It decides which model a request gets. `gateway-routing.yaml`
still needs a rule per model so Envoy can reach whichever one the router
picks. See this blueprint's README, "Real model and Service".

The block below replaces the entire `config:` key in your copy of
`values.yaml` (`extra-apps/semantic-router/values.yaml` in your cluster-values
overlay repo). Leave `persistence:`, `image:`, and `dashboard:` as you already
have them. Keep `config.version: v0.5` and
`config.global.services.management_api.bind_address`. Dropping the bind
address makes the dashboard report the router as not running.

## How the signal works

`complexity` is a signal on a recipe. The rule has a name. A decision matches
that name and a `label`, such as `hard` or `easy`. Schema v0.5 has no
`threshold` and no `hard`/`easy` candidate lists on the rule. A rule that sets
`deployment` asks that deployment to judge the prompt.

## The config

Both vLLM backends need to already be up and reachable. This block defines
the two models and the decision logic between them. It does not stand up the
model servers. Substitute your own model names for `TODO-simple-model` and
`TODO-complex-model` throughout.

```yaml
config:
  version: v0.5
  global:
    services:
      management_api:
        bind_address: "0.0.0.0"
  providers:
    defaults:
      model: "TODO-simple-model"
    models:
      - name: "TODO-simple-model"
        provider_model_id: "TODO-simple-model"
        backend_refs:
          - name: "primary"
            provider: vllm
            endpoint: "TODO-simple-vllm-service:8000"
            protocol: "http"
            weight: 100
      - name: "TODO-complex-model"
        provider_model_id: "TODO-complex-model"
        backend_refs:
          - name: "primary"
            provider: vllm
            endpoint: "TODO-complex-vllm-service:8000"
            protocol: "http"
            weight: 100
  recipes:
    - name: default
      signals:
        complexity:
          - name: task-complexity
            description: "Distinguish simple factual queries from complex reasoning tasks."
      decisions:
        - name: "hard-to-complex-model"
          description: "Complex prompts route to the bigger model."
          priority: 200
          rules:
            operator: "AND"
            conditions:
              - type: "complexity"
                name: "task-complexity"
                label: "hard"
          modelRefs:
            - model: "TODO-complex-model"
              use_reasoning: false
        - name: "easy-to-simple-model"
          description: "Simple prompts route to the smaller model."
          priority: 150
          rules:
            operator: "AND"
            conditions:
              - type: "complexity"
                name: "task-complexity"
                label: "easy"
          modelRefs:
            - model: "TODO-simple-model"
              use_reasoning: false
        - name: "default-route"
          description: "Catch-all. Anything that matches neither label."
          priority: 100
          rules:
            operator: "AND"
            conditions: []
          modelRefs:
            - model: "TODO-simple-model"
              use_reasoning: false
```

**Priority order, and the catch-all's place in it.** `decisions` are
evaluated highest-`priority` first. The first one whose `conditions` match
wins. The catch-all keeps `conditions: []`, so it matches unconditionally. It
has to sit at the lowest priority (`100` here), or it wins before the
signal-based decisions. This is the same shape as the catch-all rule in
`gateway-routing.yaml`. There, Envoy's route matching needs a fallback. Here,
the router's own decision matching needs one.

**`use_reasoning: false`** means the request is sent without that model's
extended-thinking mode. It is a per-model-ref switch. The `complexity` signal
classifies the prompt.

## Verifying it

Send an easy prompt and a hard one, then check which model each landed on:

```bash
curl -sk https://sr.<domain>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"What is the capital of France?"}]}'

curl -sk https://sr.<domain>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Write a Python function to implement a binary search tree"}]}'
```

`"model":"auto"` matters. Naming a configured model in the request body
skips classification. The router honours the client's choice and logs
`reason_code: "model_specified"`, so both prompts land on the same backend.
Only `auto` (or `MoM`) hands the choice to the router. Check the router's
logs to see what it decided:

```bash
kubectl -n semantic-router logs deploy/semantic-router -f
```

When no backend is connected, the router's classification endpoint (see the
main README's "Check a decision") checks the same decision logic without
`sr.<domain>` or a backend.

If both requests land on the same model, check the logs for
`reason_code: "model_specified"` first. That means the request named a model
instead of `auto`.

## Other signal types

`complexity` is one of several upstream signal types. This example covers only
`complexity`. Test other signal types with your models and prompts.
