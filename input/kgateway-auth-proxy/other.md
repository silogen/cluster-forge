
#############################################################################################################################################################################################
# More info:

You can enforce authentication for traffic routed through **kgateway** by integrating it with an **OAuth2 Proxy** (such as `oauth2-proxy`). This pattern is common with ingress controllers and API gateways, and kgateway's Envoy-based architecture allows for external authentication workflows similar to those used with NGINX Ingress or Istio Gateway[1][3][5]. 

## How to Integrate kgateway with oauth2-proxy for Authenticated Routing

### 1. Deploy oauth2-proxy
Deploy an OAuth2 Proxy in your cluster (for example, via Helm). Configure it to connect to your OIDC provider (e.g., Keycloak, Google, etc.) and expose an `/auth` endpoint that can be called by proxies/gateways to check user authentication[2][5].

### 2. Configure Backend Service
Set up your backend (the destination service you wish to protect) normally as a Kubernetes service.

### 3. Configure kgateway for External Authentication
Although kgateway documentation does not (yet) provide specific configuration YAML for oauth2-proxy, kgateway's Envoy and Kubernetes Gateway API foundation supports **external authentication** patterns used widely in industry[1][3]. The usual approach is:
- Configure an **HTTPRoute** (or Gateway/RoutePolicy in kgateway’s extended resources) with an external authentication policy.
- Specify the external authentication service (the oauth2-proxy `/auth` endpoint) in the policy.
- Ensure requests are routed to oauth2-proxy first. Only requests with valid authentication tokens are run through to the protected upstream service.

#### Example pattern (based on industry norms and Envoy/Ingress API):

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: HTTPRoute
metadata:
  name: airm-app-auth-route
  namespace: airm
spec:
  parentRefs:
    - name: airm-gateway
      namespace: airm
  hostnames:
    - "your-protected-app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            apiGroup: gateway.envoyproxy.io
            kind: AuthenticationFilter
            name: oauth2-auth
      backendRefs:
        - name: airm-backend
          port: 80
```

You would define the **AuthenticationFilter** custom resource to send requests to your oauth2-proxy `/auth` endpoint.  
> *Note: Syntax and naming depend on current kgateway and Envoy Gateway API versions; consult kgateway and Envoy Gateway API docs for exact resource types.*

### 4. Test the Flow
- User requests a route handled by kgateway.
- kgateway sends a subrequest to oauth2-proxy `/auth` endpoint.
- oauth2-proxy verifies the user's session/token:
  - If NOT authenticated, user is redirected to sign-in (OIDC/OAuth2).
  - If authenticated, request is proxied to your backend service.

### 5. (Optional) Forward Headers
Configure kgateway or quay upstream to forward authentication headers (e.g., `Authorization`, `X-Auth-Request-User`) as required by your app.

---

**Key Points:**
- kgateway supports "invoke external authentication"[3], which is how oauth2-proxy is integrated[2][5].
- The actual YAML structure and extension names may differ; refer to kgateway's custom resource documentation and the Envoy Gateway API for details on declaring an external authentication filter[1][3].
- This pattern closely resembles the ingress-nginx approach, but uses Gateway API resources[2][5].
- If you want automated configuration snippets, reference similar Envoy or Istio Gateway + oauth2-proxy guides as they use analogous mechanisms[4].

**Summary Table:**

| Step                | Resource                  | Purpose                                             |
|---------------------|--------------------------|-----------------------------------------------------|
| Deploy oauth2-proxy | Deployment/Service       | Handles login, token validation, /auth endpoint     |
| Define HTTPRoute    | HTTPRoute (Gateway API)  | Routes API traffic, invokes ext auth filter         |
| Auth Policy/Filter  | ExtensionRef, CRD        | Specifies to call oauth2-proxy for authentication   |
| Backend Service     | Service                  | Serves user requests **after** auth is checked      |

**You MUST consult kgateway's docs for up-to-date custom resource and extension names, as the external authentication mechanism relies on its Gateway API extensions**[1][3].

If you need an exact YAML manifest for your version of kgateway, please specify its version or share relevant cluster details.

---

API Rate limit

Here’s a clear breakdown of **Local** vs. **Global rate limiting** in kgateway, based directly on the official documentation:

---

## Local Rate Limiting

### What it is

* A **coarse-grained, first-line defense** mechanism to curtail excessive requests **locally, within each Envoy instance** (`gateway pod`)—before reaching your global rate limit service ([kgateway.dev][1]).
* Protects your rate limit servers from overload during spikes or attacks by stopping high-volume requests right at the gateway level ([kgateway.dev][1]).

### How it works

* Each Envoy pod has its own **token bucket** (configurable via `maxTokens`, `tokensPerFill`, and `fillInterval`) ([kgateway.dev][1]).
* Example: 5 Envoy pods, each limited to 10 requests/sec → **total throughput = 50 req/s**, versus global limiting which would apply one shared threshold across all instances ([kgateway.dev][1]).

### Configuration

* Defined in a `TrafficPolicy` under `rateLimit.local`.
* Can target a specific HTTP route, all routes within an HTTPRoute, or all routes served by a Gateway.
* You can also disable local rate limiting for specific routes by setting `rateLimit.local: {}` ([kgateway.dev][1]).

---

## Global Rate Limiting

### What it is

* A **distributed, centralized rate limiting system** that applies consistent limits across all Gateway instances with shared counters and logic ([kgateway.dev][2]).
* Requires an external **Rate Limit Service** that speaks Envoy’s rate limiting protocol ([kgateway.dev][2]).

### How it works

1. kgateway extracts request descriptors (like IP, path, header values).
2. Sends them to your Rate Limit Service.
3. The service evaluates and returns whether to allow or deny the request.
4. kgateway forwards or blocks accordingly, providing consistent behavior across multiple gateway instances ([kgateway.dev][2]).

### Benefits

* Centralized control over rate limits.
* Flexible, descriptor-based rules (remote address, path, user ID, generic key/value, or nested combinations) ([kgateway.dev][2]).
* Uniform user experience regardless of which Gateway handles the request ([kgateway.dev][2]).

### Configuration

* Requires:

  * A `Rate Limit Service` (external, implementing Envoy protocol).
  * A `GatewayExtension` to connect k‑gateway and the rate limit service.
  * A `TrafficPolicy` defining descriptors and referencing the extension ([kgateway.dev][2]).
* Supports combining local and global rate limits within the same `TrafficPolicy` for layered protection ([kgateway.dev][2]).

---

## Summary Table

| Feature                    | Local Rate Limiting                       | Global Rate Limiting                                     |
| -------------------------- | ----------------------------------------- | -------------------------------------------------------- |
| Scope                      | Individual Envoy instance (per-pod/pod)   | Shared across all Gateway instances                      |
| Infrastructure Requirement | No external service required              | Requires external Rate Limit Service + integration       |
| Coordination               | Independent per instance                  | Centralized, consistent behavior across gateways         |
| Use Case                   | Quick defense to protect rate limit infra | Fine-grained control, unified policy enforcement         |
| Configuration Element      | `rateLimit.local` in TrafficPolicy        | `rateLimit.global` + GatewayExtension + external service |
| Combined Usage             | Yes (stack local + global)                | Yes (common in hybrid setups)                            |

---

### When to Use Which?

* **Local** if your primary goal is to **protect your rate limit infrastructure** and handle basic bursts quickly.
* **Global** when you require **consistent, fine-grained control** across your cluster and can dedicate an external service to manage rate limits.
* **Use both together** to ensure resilience—local caps bursts, and global enforces shared policy consistency.

---

Let me know if you'd like help crafting example configs or combining both strategies in your setup!

[1]: https://kgateway.dev/docs/security/ratelimit/local/ "Local rate limiting – kgateway"
[2]: https://kgateway.dev/docs/security/ratelimit/global/ "Global rate limiting – kgateway"
