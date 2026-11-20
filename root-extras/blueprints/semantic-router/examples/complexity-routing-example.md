# Example: routing by prompt complexity

The blueprint's `values.yaml` ships this sample. `models.small` is the easy
model. `models.large` is the hard model. `models.medium` is the catch-all.
YAML anchors copy each id into `config.recipes`. The gateway chart builds one
route per id from the same entries.

Edit those three entries. Do not paste a second `config:` block over the file.
A second block drops the anchors, and the gateway chart then disagrees with
the router. Keep `config.version: v0.5` and
`config.global.services.management_api.bind_address`. Dropping the bind
address makes the dashboard report the router as not running.

## How the signal works

`complexity` is a signal on a recipe. The rule has a name. A decision matches
that name and a `label`, such as `hard` or `easy`. Schema v0.5 has no
`threshold` and no `hard`/`easy` candidate lists on the rule. A rule that sets
`deployment` asks that deployment to judge the prompt.

## The config

Both vLLM backends need to already be up and reachable. The `models` entries
name the servers. They do not start the servers.

`hard-to-large` matches label `hard` and selects `models.large`.
`easy-to-small` matches label `easy` and selects `models.small`.
`default-route` has no conditions and selects `models.medium`.

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
