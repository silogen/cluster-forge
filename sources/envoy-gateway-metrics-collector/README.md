# Envoy Gateway metrics collector

This chart installs the platform-owned OpenTelemetry pipeline used by AIM
Engine's Envoy Gateway scale-from-zero integration.

Envoy sends route activation counters to this collector over OTLP/gRPC on
port `4317`. The collector filters and normalizes those counters, then sends
them to `keda-otel-scaler.keda.svc:4317`. KEDA calls the scaler API separately
on port `4318`.

Only one collector may consume source-side delta counters from a shared
EnvoyProxy. The collector is deliberately stateless and has no request queue:
activation samples can be lost during an outage, so clients must retry cold
requests.

The collector uses a ServiceAccount without an API token and requires no
Kubernetes discovery RBAC.

## Lua validation and authorization

The activation policy uses Envoy 1.38's `handle:stats()` API. Envoy Gateway
1.8 can run that API in the data plane, but its `Strict` Lua validator does
not yet model it. While scale from zero is enabled, the shared `EnvoyProxy`
therefore uses `luaValidation: InsecureSyntax`, which checks Lua syntax
without running Envoy Gateway's controller-side safety validation.
[GHSA-xrwg-mqj6-6m22](https://github.com/envoyproxy/gateway/security/advisories/GHSA-xrwg-mqj6-6m22)
documents how untrusted Lua can expose proxy credentials and escalate access.

Treat permission to create or mutate an `EnvoyExtensionPolicy` that can
target the shared Gateway or any attached HTTPRoute as permission to run code
in the Envoy data plane. Because the Gateway currently allows routes from all
namespaces, enforce this restriction cluster-wide rather than only in
`envoy-gateway-system`. The config chart installs a cluster-wide role and
binding that grants `EnvoyExtensionPolicy` management to the current and
legacy AIRM Platform Administrator OIDC groups. Kubernetes RBAC is additive,
so other broad role bindings must not grant the same write verbs to untrusted
principals. RBAC operates on the whole resource, not only its `lua` field; use
admission policy if non-admins must retain access to other extension types.
This policy uses inline Lua; any future `ValueRef` policy must similarly
restrict write access to its ConfigMap. Return to `Strict` as soon as Envoy
Gateway's validator supports `handle:stats()`.

The Envoy filter order explicitly places both `ext_authz` and `rbac` before
Lua. Envoy Gateway implements `SecurityPolicy.authorization` with the RBAC
filter, while Gateway-scoped external authorization uses `ext_authz`. Requests
rejected by either authorization path therefore do not increment activation
counters or trigger scale from zero.

Cluster Forge currently keeps the AIM Engine and CRD charts together at
`0.2.5`. That release does not expose the Envoy provider or external-collector
ownership values, so the platform resources are staged ahead of the package
cutover. Upgrade both AIM charts atomically once a compatible release exists,
then set `scaleFromZero.gatewayProvider=envoyGateway` and
`scaleFromZero.gatewayMetricsCollector.management=external`.
