---
status: accepted
date: 2026-09-28
---

# The model routes of the demo ask for a Dex token

The `demo` and `demo-cpu` profiles put a `SecurityPolicy` of Envoy Gateway on
every model route of `workloads.<domain>`. The policy asks for a JWT of the
OIDC issuer, Dex in the demo, with the audience `aiwb`. A request without a
valid token gets 401. The aiwb package makes the policy and a
`ReferenceGrant`, so that Envoy reads the keys from the Dex Service in the
cluster. `just token` gets a token with the password grant of Dex and prints
a curl example. A token is valid for 7 days.

The aiwb chart has put no access control on the model routes since
silogen/core#4288 removed cluster-auth. The full cluster-forge installation
closes the routes with ai-gateway-discovery and API keys from OpenBao
(EAI-7302). The demo has neither, so on 2026-09-28 a Llama model on a demo
node with a public address answered requests from the internet without a
token.

## Considered options

- ai-gateway-discovery with API keys, as in full cluster-forge. Rejected: it
  needs the Envoy AI Gateway, the Gateway API Inference Extension CRDs, one
  more Pod for each model, and OpenBao with External Secrets for the API-key
  page. The demo exists to be small. The controller also closes the model
  routes only in its last reconcile step, so the routes stay open when an
  earlier step fails.
- A policy that denies every request to the model routes. Rejected: it keeps
  the demo small, and the UI chat still works because it calls the model
  inside the cluster, but a user cannot show a call to the model API.
- No policy, and a firewall in front of the node. Rejected as the only
  protection: the installer does not control the firewall of the node, and
  a firewall does not identify the caller.

## Consequences

- Any user who can log in to Dex can call every model. There are no keys for
  each model.
- Envoy checks only the signature and the expiry of a token. A token cannot
  be revoked before it expires.
- The `expiry.idTokens` value of the `dex` package is 168h, and it also sets
  the lifetime of the tokens that the AIWB UI gets. The UI keeps its own
  session of 8 hours.
- Dex keeps its signing keys in memory. A restart of the Dex Pod makes new
  keys, and every token stops working. The policy sets `cacheDuration: 60s`
  on the keys, so a new token works within one minute of the restart. With
  the default of 5 minutes, a new token got 401 for that long.
- A customer who replaces the `dex` package sets the `oidc` block of the
  aiwb package, and the policy follows the issuer, the audience and the JWKS
  URL of that block. The `workloadsJwt.jwksService` value names the Service
  that serves the keys.
