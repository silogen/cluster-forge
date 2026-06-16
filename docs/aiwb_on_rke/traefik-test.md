# TEST instructions

1. Create cluster

```bash
HOST_IP=10.0.255.201
ssh $HOST_IP
mkdir aiwb && cd aiwb
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/create_rke.sh | sudo bash -s -- aiwb-test.silogen.ai
```

---

2. Deploy the base stack with the Traefik Gateway

This runs `install_base_traefik.sh`, which installs cert-manager, MetalLB, the
Gateway API CRDs, Traefik (as the Gateway API controller), and the `https`
Gateway in `envoy-gateway-system` — plus the rest of the AIWB base stack.

> [!IMPORTANT]
> **Provide the TLS certificate BEFORE running the script.** The Gateway
> terminates TLS with the `cluster-tls` Secret in `envoy-gateway-system`. If you
> don't supply one, the script generates a *self-signed* cert (browser-untrusted).
>
> To use the real Let's Encrypt cert for `aiwb-test.silogen.ai` (from the
> 1Password "Certificates" vault), create these two files in the directory you
> run the script from, then the script auto-creates the `cluster-tls` Secret:
>
> - `fullchain.pem` — certificate chain (apex + wildcard)
> - `privkey.pem` — private key
>
> Override the filenames with `TLS_CERT_FILE` / `TLS_KEY_FILE` if needed.

The URL pins the *script* to the `test-aiwb` branch, and the script also clones
its *sources* (Helm charts) — so both must come from `test-aiwb` until it merges.
`test-aiwb` vendors charts that are not on `main` yet (e.g. `minio-operator`,
`minio-tenant`, `minio-tenant-config`) and uses a different layout for others
(e.g. `amd-gpu-operator-config`). Cloning sources from `main` therefore fails
mid-install, so set `CLUSTER_FORGE_BRANCH=test-aiwb`. Once `test-aiwb` is merged
to `main`, this override can be dropped (the script defaults to `main`).

```bash
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/install_base_traefik.sh | sudo CLUSTER_FORGE_DIR=".tmp/cf" CLUSTER_FORGE_RELEASE=v2.1.3 CLUSTER_FORGE_MANUAL_REF=test-aiwb bash -s -- aiwb-test.silogen.ai
```

---

3. Workaround needed for traefik endpoints

```shellscript
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/fix_traefik_endpoints.sh | sudo bash -s -- aiwb-test.silogen.ai
```

---

4. Test it

```bash
✅ AIWB application is ready

💡 Verification commands:
   kubectl get pods -n keycloak
   kubectl get pods -n aiwb
   kubectl get pods -n kaiwo-system
   kubectl get pods -n keda
   kubectl get pods -n otel-lgtm-stack
   kubectl get pods -n cnpg-system
   kubectl get pods -n kube-amd-gpu
   kubectl get cluster --all-namespaces

💡 Access:
   Gateway IP: 10.0.255.201:8080
   AIWB UI: https://aiwbui.aiwb-test.silogen.ai
   AIWB API: https://aiwbapi.aiwb-test.silogen.ai
   Keycloak: https://kc.aiwb-test.silogen.ai

   Ensure DNS points aiwbui.aiwb-test.silogen.ai, aiwbapi.aiwb-test.silogen.ai, and kc.aiwb-test.silogen.ai to 10.0.255.201

💡 Keycloak Admin Credentials:
   Username: silogen-admin
   Password: placeholder
   Admin Console: http://aiwb-test.silogen.ai:8080/admin

💡 AIWB User Login:
   Username: devuser@aiwb-test.silogen.ai
   Password: placeholder

📊 Observability (Grafana, Prometheus, Loki, Tempo):
   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000
   Access Grafana at: http://localhost:3000
   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090
   Access Prometheus at: http://localhost:9090

ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md
```
