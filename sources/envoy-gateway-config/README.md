# Envoy Gateway + AI Gateway (shared listener)

Single `Gateway` `https` on `:443` serves apps (`HTTPRoute`) and AI (`AIGatewayRoute`) by hostname.

## Architecture

- **Envoy Gateway** auto-creates a MetalLB `LoadBalancer` for external `:443`
- **`https` ClusterIP** (optional, default on) is only for CoreDNS `*.domain` rewrite — not the external front door
- **Envoy AI Gateway** controller connects via `extensionManager` on the envoy-gateway Helm chart
- **`GatewayConfig` `ai-extproc`** adds the ext_proc sidecar to the shared data plane

## Values

| Value | Default | Purpose |
|-------|---------|---------|
| `gatewayDnsService.enabled` | `true` | Stable ClusterIP `https` for in-cluster DNS |
| `k8sApiPassthrough.enabled` | `false` | TLS passthrough to K8s API on `:6443` |

**Do not enable `k8sApiPassthrough`** when node-ip equals the MetalLB pool IP (cluster-bloom default). Envoy `:6443` hijacks pod→apiserver traffic and breaks controllers.

## AI routes

Create `AIGatewayRoute` resources parented to `Gateway/https` in `envoy-gateway-system`. Match on `Host: ai.<domain>` and `x-ai-eg-model` header.

See `~/dev/envoy-ai-gateway-shared-listener/` for a standalone reference bundle.
