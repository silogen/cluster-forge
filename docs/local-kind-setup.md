# Local Kind Cluster Setup Guide

This guide explains how to set up cluster-forge on a local Kind (Kubernetes in Docker) cluster for development and testing purposes.

## Overview

The local Kind setup provides a minimal, resource-efficient deployment of cluster-forge suitable for:
- Local development and testing
- Learning cluster-forge architecture
- Debugging and troubleshooting
- CI/CD testing on limited resources

## Prerequisites

Before starting, ensure you have the following tools installed:

- **Docker** - Kind runs Kubernetes nodes as Docker containers
- **Kind** - Kubernetes in Docker (https://kind.sigs.k8s.io/)
- **kubectl** - Kubernetes CLI tool
- **helm** - Kubernetes package manager (v3.0+)
- **yq** - YAML processor for configuration updates
- **openssl** - For generating secure passwords

### Installation Commands

```bash
# macOS (using Homebrew)
brew install kind kubectl helm yq openssl

# Linux
# Install Docker first, then:
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Install kubectl, helm, yq as needed
```

## Quick Start

### 1. Create a Kind Cluster

```bash
cd cluster-forge

# Delete existing cluster if any
kind delete cluster --name cluster-forge-local

# Create new cluster with configuration
kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml
```

### 2. Run the Setup Script

```bash
./scripts/bootstrap-kind-cluster.sh [OPTIONS]
```

**Options:**
- `-s, --silogen-core PATH` - Path to silogen-core repository (default: auto-detect)
- `-b, --build-local` - Build and use local AIRM images instead of published ones
- `-i, --skip-preload` - Skip image preloading (faster initial setup, but images won't be cached in host Docker for cluster recreation)
- `-h, --help` - Show help message

**Examples:**

```bash
# Basic setup (uses localhost.local domain)
./scripts/bootstrap-kind-cluster.sh

# Build local images from custom path
./scripts/bootstrap-kind-cluster.sh --build-local --silogen-core ~/code/silogen-core

# Quick setup skipping image preload
./scripts/bootstrap-kind-cluster.sh --skip-preload
```

The script will automatically:
1. Apply AMD certificates (if available)
2. Verify prerequisites
3. Create necessary namespaces
4. Deploy ArgoCD
5. Deploy and initialize OpenBao (secrets management)
6. Deploy and initialize Gitea (internal git repository)
7. Create all cluster-forge ArgoCD applications

The setup takes approximately 2-3 minutes to complete.

**⚠️ Important:** The bootstrap script is **not idempotent**. Running it multiple times will regenerate secrets, which may cause issues with existing deployments. If you need to update configurations, see the "Updating Application Configurations" section below.

### 3. Monitor Deployment

Watch ArgoCD applications sync:

```bash
# List all applications
kubectl get applications -n argocd

# Watch application status
watch kubectl get applications -n argocd

# Check specific app details
kubectl describe application <app-name> -n argocd

# Check pod status across all namespaces
kubectl get pods -A
```

## Architecture

### Minimal Component Set

The local Kind configuration deploys a minimal set of components:

**Core Infrastructure:**
- ArgoCD - GitOps controller
- Cert-Manager - Certificate management
- OpenBao - Secrets management
- External Secrets - Secrets operator
- Gitea - Internal Git repository

**Networking:**
- Gateway API - Next-gen ingress
- MetalLB - Load balancer (configured for Kind)
- KGateway - Gateway implementation

**Storage:**
- MinIO Operator - Object storage operator
- MinIO Tenant - S3-compatible storage (reduced resources)
- CNPG Operator - PostgreSQL operator

### Resource Adjustments

The local configuration makes the following resource adjustments:

**MinIO Tenant:**
- Storage: 500Gi → 10Gi
- Memory: Default → 512Mi request, 1Gi limit
- CPU: Default → 100m request, 500m limit
- Storage class: `direct` → `standard`
- Object lock: Disabled for simplicity

**Optional Components:**
Components commented out by default to reduce resource usage:
- Prometheus & monitoring stack
- Kyverno policy engine
- GPU operators
- ML/AI components (KubeRay, Kueue)

## Configuration Files

### Location

- **Main config:** `root/values_local_kind.yaml`
- **MinIO config:** `sources/minio-tenant/values_local_kind.yaml`
- **Setup script:** `scripts/bootstrap-kind-cluster.sh`

### Customization

To enable optional components, edit `root/values_local_kind.yaml`:

```yaml
enabledApps:
  - argocd
  - argocd-config
  # ... existing apps ...
  
  # Uncomment to enable monitoring
  - prometheus-crds
  - opentelemetry-operator
  - otel-lgtm-stack
  
  # Uncomment to enable policy engine
  - kyverno
  - kyverno-config
```

To adjust resource requirements further, edit component-specific values files in the `sources/` directory.

## Accessing Services

After deployment, access services via port-forwarding:

### ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Open: https://localhost:8080
# Username: admin
```

### Gitea UI

```bash
kubectl port-forward svc/gitea-http -n cf-gitea 3000:3000

# Get credentials
kubectl -n cf-gitea get secret gitea-admin-credentials \
  -o jsonpath="{.data.username}" | base64 -d
kubectl -n cf-gitea get secret gitea-admin-credentials \
  -o jsonpath="{.data.password}" | base64 -d

# Open: http://localhost:3000
```

### OpenBao UI

```bash
kubectl port-forward svc/openbao-active -n cf-openbao 8200:8200

# Get root token
kubectl -n cf-openbao get secret openbao-keys \
  -o jsonpath='{.data.root_token}' | base64 -d

# Open: http://localhost:8200
```

### AIRM UI (Local Development)

```bash
# Port forward AIRM services
kubectl port-forward -n airm svc/airm-ui 8000:80
kubectl port-forward -n airm svc/airm-api 8001:80
kubectl port-forward -n keycloak svc/keycloak-old-http 8080:80

# Open: http://localhost:8000
# Login with: devuser@localhost.local / (password from Keycloak realm)
```

**Note:** The AIRM UI is pre-configured for local port-forwarding with `NEXTAUTH_URL=http://localhost:8000` in the local Kind values.

## Troubleshooting

### Common Issues

#### 1. Applications Stuck in Progressing State

```bash
# Check application details
kubectl describe application <app-name> -n argocd

# View application sync status
kubectl get application <app-name> -n argocd -o yaml

# Check pod status
kubectl get pods -n <namespace>

# View pod logs
kubectl logs -n <namespace> <pod-name>
```

#### 2. Insufficient Resources

If pods fail to schedule due to insufficient resources:

```bash
# Check node resources
kubectl top nodes
kubectl describe nodes

# Check pod resource requests
kubectl get pods -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory

# Scale down or disable optional components in root/values_local_kind.yaml
```

#### 3. AIRM Not Starting

Common issues with AIRM deployment:

```bash
# Check AIRM application sync status
kubectl get application airm -n argocd -o yaml

# Check ExternalSecrets (should exist and be synced)
kubectl get externalsecrets -n airm

# Check if secrets were created
kubectl get secrets -n airm

# Check pod status
kubectl get pods -n airm

# View logs from failing pods
kubectl logs -n airm <pod-name>
```

#### 4. Keycloak Realm Issues

```bash
# Check if realm was imported
kubectl logs -n keycloak deployment/keycloak-old | grep "Realm 'airm' imported"

# Check realm configuration
kubectl get configmap keycloak-realm-templates -n keycloak-config -o yaml
```

#### 5. Gitea Repository Initialization

```bash
# Check Gitea init job logs
kubectl logs -n cf-gitea job/gitea-init-job

# Verify repositories were created
kubectl port-forward -n cf-gitea svc/gitea-http 3000:3000
# Then check http://localhost:3000/cluster-org
```

### Resetting the Cluster

To start fresh:

```bash
# Delete the Kind cluster
kind delete cluster --name cluster-forge-local

# Recreate and setup
kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml
./scripts/bootstrap-kind-cluster.sh
```

## Resource Requirements

### Minimum System Requirements

- **CPU:** 8 cores recommended (4 cores minimum for basic setup)
- **Memory:** 16GB RAM recommended (8GB minimum for basic setup, 12GB+ for full AIRM stack)
- **Disk:** 30GB free space for Docker images and storage

### Estimated Resource Usage

**Infrastructure only (without AIRM):**
- **Control plane:** ~1GB memory, 1 CPU
- **ArgoCD:** ~500MB memory
- **Gitea + PostgreSQL:** ~1GB memory
- **OpenBao:** ~256MB memory
- **Operators:** ~1-2GB memory

Total: ~4-5GB memory usage

**With AIRM enabled (full stack):**
- All infrastructure above plus:
- **Keycloak:** ~1GB memory
- **RabbitMQ:** ~512MB memory
- **PostgreSQL (CNPG):** ~512MB memory
- **Kyverno:** ~500MB memory
- **MinIO:** ~1GB memory
- **AIRM services:** ~2-3GB memory
- **Monitoring:** ~500MB memory

Total: ~10-12GB memory usage

## Configuration Files

### Key Files

- **Kind cluster config:** `kind-cluster-config.yaml` - Defines the Kind cluster with port mappings
- **Main values:** `root/values_local_kind.yaml` - Configuration for all cluster-forge applications
- **Setup script:** `scripts/bootstrap-kind-cluster.sh` - Automated deployment script

### Customization

To enable or disable components, edit `root/values_local_kind.yaml`:

```yaml
enabledApps:
  - argocd
  - argocd-config
  # ... core infrastructure ...
  
  # Optional: Comment out to disable
  # - kyverno
  # - kyverno-config
  # - opentelemetry-operator
```

To adjust AIRM configuration for local development:

```yaml
apps:
  airm:
    path: airm/0.2.7
    namespace: airm
    helmParameters:
      - name: airm-api.airm.appDomain
        value: "localhost.local"
      - name: airm-api.airm.frontend.nextauthUrl
        value: "http://localhost:8000"  # For local port-forwarding
```

## Next Steps

- **Monitor deployment:** `watch kubectl get applications -n argocd`
- **Access ArgoCD UI** to observe GitOps workflow
- **Port-forward services** for local development and testing
- **Check the main README.md** for production deployment guidelines

## Common Development Tasks

### Updating Application Configurations

```bash
# 1. Edit configuration
vim root/values_local_kind.yaml

# 2. Apply changes (recreates ArgoCD applications)
helm template root -f root/values_local_kind.yaml --kube-version=1.33 | kubectl apply -f -

# 3. Wait for sync (automatic with automated sync policy)
watch kubectl get applications -n argocd
```

### Viewing Logs

```bash
# All AIRM pods
kubectl logs -n airm -l app.kubernetes.io/part-of=airm --tail=50

# Specific service
kubectl logs -n airm deployment/airm-api -f

# ArgoCD application controller (for sync issues)
kubectl logs -n argocd statefulset/argocd-application-controller
```

### Quick Reset Without Rebuilding Cluster

```bash
# Delete all ArgoCD applications (keeps ArgoCD itself)
kubectl delete applications -n argocd --all

# Reapply configuration
./scripts/bootstrap-kind-cluster.sh
```

## References

- [Kind Documentation](https://kind.sigs.k8s.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Cluster-Forge Bootstrap Guide](../scripts/bootstrap.md)
- [Main README](../README.md)
