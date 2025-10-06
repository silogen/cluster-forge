# HOW-TO

#### 1. Deploy a simple workload webapp

#### 2. Add the URL simple webapp to the valid redirect URIs in the Keycloak client for airm (i.e. 354a0fa1-35ac-4a6d-9c4d-d661129c2cd0)

#### 3. Deploy this oauth-proxy deployment that is accepting traffic and upstreaming to the service that we want to add the authentication layer on it

#### 4. All needed URLS are obtained form the keycloak realm provider definition URL: https://kc.silogen.ai/realms/airm/.well-known/openid-configuration

https://kc.plat-dev-2.silogen.ai/realms/airm/.well-known/openid-configuration

```
OAUTH2_PROXY_PROVIDER=airm
OAUTH2_PROXY_LOGIN_URL=https://kc.plat-dev-2.silogen.ai/realms/airm/protocol/openid-connect/auth
OAUTH2_PROXY_REDEEM_URL=https://kc.plat-dev-2.silogen.ai/realms/airm/protocol/openid-connect/token
OAUTH2_PROXY_VALIDATE_URL=https://kc.plat-dev-2.silogen.ai/realms/airm/protocol/openid-connect/userinfo
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_COOKIE_SECRET=0dRxp1UXNwxaQZCGhICTug==
OAUTH2_PROXY_CLIENT_ID=354a0fa1-35ac-4a6d-9c4d-d661129c2cd0
OAUTH2_PROXY_CLIENT_SECRET=<REPLACE_FOR_VALIDSECRET>
OAUTH2_PROXY_COOKIE_REFRESH=1m
OAUTH2_PROXY_COOKIE_EXPIRE=30m
OAUTH2_PROXY_UPSTREAMS=https://workloads.plat-dev-2.silogen.ai/
OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
OAUTH2_PROXY_FORCE_HTTPS=false
```

-p 8085:4180 

image: quay.io/oauth2-proxy/oauth2-proxy:latest


#### 5. Setup the KGateway to use that service to authenticate the user
https://kgateway.dev/docs/security/external-auth/

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
    - "workloads.silogen.ai"
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
