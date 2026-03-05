# Local Development Setup Guide (`setup-local-dev.sh`)

This guide explains the **idempotent** local development setup script that deploys the full AIRM + AIWB stack on a Kind cluster, building images from your local `~/core` repository.

## How It Differs from `bootstrap-kind-cluster.sh`

| | `bootstrap-kind-cluster.sh` | `setup-local-dev.sh` |
|---|---|---|
| **Idempotent** | No — regenerates secrets on re-run | Yes — skips healthy components |
| **Local images** | Optional flag | Builds from `~/core` by default |
| **AIRM + AIWB** | Deploys published images | Builds and deploys from local source |
| **Keycloak** | Base realm import only | Configures dev users, redirect URIs, syncs secrets |
| **Access** | Port-forward only | NodePort services on fixed localhost ports |
| **Re-run safe** | Requires cluster deletion | Safe to re-run anytime (including after laptop restart) |

## Prerequisites

- **Docker** with at least 16 GB memory allocated
- **Kind** — `kind` CLI installed
- **kubectl**, **helm** (v3+), **yq**, **openssl**
- **Core repository** cloned at `~/core` (or set `LLM_STUDIO_CORE_PATH`)
- **GHCR access** — either `docker login ghcr.io` or set `GHCR_TOKEN` env var

## Quick Start

```bash
# 1. Create the Kind cluster (only needed once)
kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml

# 2. Run the setup
./scripts/setup-local-dev.sh
```

The script takes ~5-10 minutes on first run. Re-runs skip healthy components and finish much faster.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_STUDIO_CORE_PATH` | `~/core` | Path to the core repository |
| `GHCR_TOKEN` | *(none)* | GitHub token with `read:packages` scope |
| `GHCR_USERNAME` | `git config user.name` | GitHub username for GHCR auth |
| `SKIP_LOCAL_BUILD=1` | *(off)* | Skip building local AIRM/AIWB images |
| `SKIP_IMAGE_PRELOAD=1` | *(off)* | Skip pre-loading container images into Kind |
| `FORCE_REDEPLOY=1` | *(off)* | Ignore readiness checks, redeploy everything |

### Examples

```bash
# Default — builds from ~/core, sets up everything
./scripts/setup-local-dev.sh

# Custom core repo path
LLM_STUDIO_CORE_PATH=/home/me/projects/core ./scripts/setup-local-dev.sh

# Skip image builds (use published images via GHCR)
SKIP_LOCAL_BUILD=1 ./scripts/setup-local-dev.sh

# Force full redeploy after config changes
FORCE_REDEPLOY=1 ./scripts/setup-local-dev.sh
```

## What the Script Does (Step by Step)

### 1. Cluster Check & Certificates

Verifies a Kind cluster is running and applies corporate CA certificates if `scripts/fix_kind_certs.sh` exists. Checks that all prerequisites (`kubectl`, `helm`, `yq`, `openssl`) are installed.

### 2. Namespaces

Creates all required namespaces idempotently:
`argocd`, `cf-gitea`, `cf-openbao`, `airm`, `aim-system`, `keycloak`, `aiwb`

### 3. GHCR Pull Secrets

Detects GHCR credentials in one of three ways (in order):
1. `GHCR_TOKEN` environment variable
2. Existing `docker login ghcr.io` credentials in `~/.docker/config.json`
3. Falls back to building all images locally

Creates `ghcr-pull-secret` in `airm`, `aim-system`, `keycloak`, and `aiwb` namespaces and patches the `default` ServiceAccount in each.

### 4. Storage Class

Creates a `default` StorageClass using Kind's `local-path` provisioner so PVCs bind correctly.

### 5. ArgoCD

Deploys ArgoCD from vendored Helm charts. Skipped if already running. Waits for the application controller, Redis, and repo server to be ready.

### 6. OpenBao (Secrets Management)

Deploys OpenBao and runs the initialization job (creates unseal keys, root token, seeds secrets). On re-run:
- If already running but **sealed** (e.g. after laptop restart), **automatically unseals** it
- Triggers an ExternalSecrets refresh so all secrets sync immediately

### 7. Pre-load Container Images

Pulls common images on the Docker host and loads them into Kind to avoid Docker Hub rate limits and GHCR auth issues inside the cluster:

| Image | Purpose |
|-------|---------|
| `ghcr.io/silogen/keycloak-init:0.1` | Keycloak realm initialization |
| `quay.io/keycloak/keycloak:26.0.0` | Keycloak server |
| `busybox:1.37.0` | Init containers (readiness checks) |
| `postgres:17-alpine` | CNPG init containers |
| `docker.io/liquibase/liquibase:4.31` | Database migrations |
| `rabbitmq:4.1.1-management` | AIRM message broker |

Skips images already present in Kind. Disable with `SKIP_IMAGE_PRELOAD=1`.

### 8. Build Local Images

Calls `scripts/build-local-images.sh` to build AIRM and AIWB images from the core repo and load them into Kind with the `:local` tag. Handles corporate proxy CA certificates automatically.

Triggered when:
- Core repo is found at `LLM_STUDIO_CORE_PATH` (default `~/core`), OR
- No GHCR credentials are available (local build is the only path)

Skipped with `SKIP_LOCAL_BUILD=1`.

### 9. Gitea (Internal Git)

Deploys Gitea and runs initialization jobs. Generates admin credentials on first run, preserves them on re-run.

### 10. Push Repositories to Gitea

Pushes `cluster-forge` and `core` repositories into the internal Gitea instance. ArgoCD watches these repos for application definitions.

### 11. Deploy ArgoCD Applications

Renders the root Helm template with `values_local_kind.yaml` and applies all ArgoCD Application resources. This triggers the full deployment of all enabled components through ArgoCD's GitOps sync.

### 12. NodePort Services

Creates NodePort services that map to fixed host ports via Kind's `extraPortMappings`:

| Service | NodePort | Host Port | URL |
|---------|----------|-----------|-----|
| AIRM UI | 30080 | 8000 | http://localhost:8000 |
| AIWB UI | 30081 | 8001 | http://localhost:8001 |
| Keycloak | 30082 | 8080 | http://localhost:8080 |
| AIRM API | 30083 | 8083 | http://localhost:8083 |
| AIWB API | 30084 | 8084 | http://localhost:8084 |

### 13. Bootstrap AIRM Agent

Creates RabbitMQ vhosts, users, and permissions needed by the AIRM agent. Seeds the `airm-rabbitmq-common-vhost-user` secret. Waits for RabbitMQ to be ready first.

### 14. Configure Keycloak

Configures Keycloak for local development via its Admin API:
- Creates an `admin`/`admin` user in the master realm (for Keycloak console access)
- Creates or updates `devuser@amd.com` / `password` in the `airm` realm
- Assigns the `Platform Administrator` role to devuser
- Adds `http://localhost:*` redirect URIs to OIDC clients (for Swagger, UI login)
- Syncs the Keycloak client secret to `airm` and `aiwb` namespaces (so UI auth works)

### 15. Patch NEXTAUTH_URL

Patches the `NEXTAUTH_URL` environment variable on `airm-ui` and `aiwb-ui` deployments to use `http://localhost:8000` and `http://localhost:8001` respectively. Disables ArgoCD `selfHeal` on those apps so the patches persist.

### 16. AIRM Demo Onboarding

Registers a local cluster with the AIRM API using `devuser@amd.com` credentials. Updates the agent secret with API-issued credentials so heartbeats are tracked.

## Port Map

```
Host Port  →  Service
─────────────────────────────────────
8000       →  AIRM UI
8001       →  AIWB UI
8080       →  Keycloak
8083       →  AIRM API  (Swagger: /docs)
8084       →  AIWB API  (Swagger: /docs)
5432       →  PostgreSQL (direct access)
9090*      →  ArgoCD    (requires port-forward)
3000*      →  Gitea     (requires port-forward)
8200*      →  OpenBao   (requires port-forward)

* These services still require manual port-forward
```

## Accessing Services

### Direct Access (NodePort — no port-forward needed)

| Service | URL | Credentials |
|---------|-----|-------------|
| AIRM UI | http://localhost:8000 | `devuser@amd.com` / `password` |
| AIWB UI | http://localhost:8001 | `devuser@amd.com` / `password` |
| AIRM Swagger | http://localhost:8083/docs | OAuth via Keycloak |
| AIWB Swagger | http://localhost:8084/docs | OAuth via Keycloak |
| Keycloak Admin | http://localhost:8080/admin | `admin` / `admin` |

### Port-Forward Required

```bash
# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 9090:443
# Open: https://localhost:9090
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Gitea
kubectl port-forward svc/gitea-http -n cf-gitea 3000:3000
# Open: http://localhost:3000

# OpenBao
kubectl port-forward svc/openbao-active -n cf-openbao 8200:8200
# Open: http://localhost:8200
# Token: kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.root_token}' | base64 -d
```

## Idempotency Behavior

The script is safe to re-run at any time. Here's what happens on each re-run:

| Component | Already Healthy | Unhealthy / Missing |
|-----------|----------------|---------------------|
| Namespaces | No-op | Created |
| GHCR secrets | Overwritten (safe) | Created |
| ArgoCD | Skipped | Deployed + waited |
| OpenBao | Skipped (unsealed if needed) | Deployed + initialized |
| Image pre-load | Skipped per image | Pulled + loaded |
| Local image build | Rebuilt (always) | Built |
| Gitea | Skipped | Deployed + initialized |
| Git push | Fast push (no-op if up to date) | Full push |
| ArgoCD apps | Re-applied (idempotent) | Created |
| NodePort services | Re-applied (idempotent) | Created |
| AIRM agent bootstrap | Skipped if secret exists | Created |
| Keycloak config | Re-applied (idempotent) | Configured |
| NEXTAUTH_URL patch | Skipped if correct | Patched |
| AIRM onboarding | Skipped if cluster registered | Registered |

## After Laptop Restart

The Kind cluster persists across Docker restarts. After a reboot:

1. Start Docker
2. Run `./scripts/setup-local-dev.sh`

The script will detect the existing cluster, **unseal OpenBao**, refresh ExternalSecrets, and skip everything else that's already healthy. This typically takes under a minute.

## Resetting the Cluster

```bash
# Full reset
kind delete cluster --name cluster-forge-local
kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml
./scripts/setup-local-dev.sh
```

## Configuration Files

| File | Purpose |
|------|---------|
| `kind-cluster-config.yaml` | Kind cluster definition with `extraPortMappings` |
| `root/values_local_kind.yaml` | Helm values for all ArgoCD applications |
| `scripts/setup-local-dev.sh` | Main setup script (this doc) |
| `scripts/build-local-images.sh` | Builds AIRM/AIWB Docker images from local source |
| `scripts/fix_kind_certs.sh` | Injects corporate CA certificates into Kind node |

## Troubleshooting

### OpenBao Sealed After Restart

The script handles this automatically. If you need to unseal manually:

```bash
UNSEAL_KEY=$(kubectl get secret openbao-keys -n cf-openbao -o jsonpath='{.data.unseal_key}' | base64 -d)
kubectl exec openbao-0 -n cf-openbao -- bao operator unseal "${UNSEAL_KEY}"
```

### ExternalSecrets Stuck in SecretSyncedError

Usually caused by OpenBao being sealed. After unsealing, trigger a refresh:

```bash
# The setup script does this automatically, but if needed manually:
for es in $(kubectl get externalsecrets -A --no-headers -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name" | tr -s ' '); do
    ns=$(echo "$es" | cut -d' ' -f1)
    name=$(echo "$es" | cut -d' ' -f2)
    kubectl annotate externalsecret "$name" -n "$ns" force-sync="$(date +%s)" --overwrite
done
```

### Docker Hub Rate Limits (ImagePullBackOff)

The script pre-loads common Docker Hub images. If you still hit limits:

```bash
# Login to Docker Hub for higher limits
docker login

# Manually pull and load an image
docker pull <image>
kind load docker-image <image> --name cluster-forge-local
```

### Keycloak Login Redirect Errors

If you see `Invalid parameter: redirect_uri`, re-run the setup script — it adds all `localhost:*` redirect URIs to Keycloak clients.

### Pods Stuck in ImagePullBackOff for GHCR Images

Ensure GHCR credentials are set up:

```bash
# Option A: Docker login
docker login ghcr.io

# Option B: Token
GHCR_TOKEN=ghp_xxx ./scripts/setup-local-dev.sh
```

### NEXTAUTH_URL Errors / DNS_PROBE_STARTED

The script patches `NEXTAUTH_URL` to `http://localhost:8000` (AIRM) and `http://localhost:8001` (AIWB). If ArgoCD reverts this, re-run the script — it disables selfHeal before patching.
