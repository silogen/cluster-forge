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

Create a Kind cluster with appropriate configuration:

```bash
cd cluster-forge

# Create cluster with default configuration
kind create cluster --name cluster-forge-local

# OR with custom configuration (recommended for larger deployments)
cat > kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  extraMounts:
  - hostPath: /tmp/kind-storage
    containerPath: /var/local-path-provisioner
EOF

kind create cluster --name cluster-forge-local --config kind-config.yaml
```

### 2. Run the Setup Script

```bash
./scripts/setup-local-dev.sh [domain]

# Example with default localhost:
./scripts/setup-local-dev.sh localhost

# Example with custom domain (requires /etc/hosts setup):
./scripts/setup-local-dev.sh local.dev
```

The script will:
1. Verify prerequisites
2. Create necessary namespaces
3. Deploy ArgoCD
4. Deploy and initialize OpenBao (secrets management)
5. Deploy and initialize Gitea (internal git repository)
6. Create the root cluster-forge ArgoCD application

### 3. Monitor Deployment

Watch ArgoCD applications sync:

```bash
# List all applications
kubectl get applications -n argocd

# Watch application status
kubectl get applications -n argocd -w

# Check specific app details
kubectl describe application <app-name> -n argocd
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
- **Setup script:** `scripts/setup-local-dev.sh`

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

### MinIO Console

```bash
kubectl port-forward svc/default-minio-tenant-console -n minio-tenant-default 9443:9443

# Get credentials from OpenBao or external secrets
# Open: https://localhost:9443
```

## Troubleshooting

### Common Issues

#### 1. Applications Stuck in Progressing State

```bash
# Check application details
kubectl describe application <app-name> -n argocd

# View application events
kubectl get events -n <app-namespace> --sort-by='.lastTimestamp'

# Check pod status
kubectl get pods -n <namespace>
```

#### 2. Insufficient Resources

If pods fail to schedule due to insufficient resources:

```bash
# Check node resources
kubectl top nodes
kubectl describe node <node-name>

# Scale down or disable optional components in values_local_kind.yaml
```

#### 3. Storage Issues

MinIO and other components require persistent storage:

```bash
# Check storage classes
kubectl get storageclass

# Check PVCs
kubectl get pvc -A

# If PVCs are pending with "storageclass 'default' not found":
kubectl create -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
EOF

# If using custom storage location, ensure Docker can access it
```

#### 4. AIRM Namespace Issues

If AIRM fails to sync with "namespace not found" errors:

```bash
# Create the airm namespace manually
kubectl create namespace airm

# Manually trigger sync
kubectl patch application airm -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

#### 5. Missing CRDs

If applications fail with "CRD not found" errors:

```bash
# Check what CRDs are installed
kubectl get crd

# Ensure prometheus-crds and opentelemetry-operator are enabled in values_local_kind.yaml
# They are required for AIRM and cluster-auth

# Wait for CRD installation, then retry sync
kubectl wait --for condition=established --timeout=60s crd/servicemonitors.monitoring.coreos.com
kubectl wait --for condition=established --timeout=60s crd/opentelemetrycollectors.opentelemetry.io
```

#### 4. Initialization Jobs Failing

```bash
# Check OpenBao init job
kubectl logs -n cf-openbao job/openbao-init-job

# Check Gitea init job
kubectl logs -n cf-gitea job/gitea-init-job

# Restart job if needed
kubectl delete job <job-name> -n <namespace>
# Re-run setup script
```

### Getting Logs

```bash
# Application logs
kubectl logs -n <namespace> <pod-name>

# Previous container logs (if crashed)
kubectl logs -n <namespace> <pod-name> --previous

# Follow logs
kubectl logs -n <namespace> <pod-name> -f

# All pods in namespace
kubectl logs -n <namespace> --all-containers=true --prefix=true
```

### Resetting the Cluster

To start fresh:

```bash
# Delete the Kind cluster
kind delete cluster --name cluster-forge-local

# Recreate
kind create cluster --name cluster-forge-local

# Re-run setup
./scripts/setup-local-dev.sh localhost
```

## Resource Requirements

### Minimum System Requirements

- **CPU:** 8 cores recommended (4 cores minimum for basic setup)
- **Memory:** 16GB RAM recommended (8GB minimum for basic setup, 12GB+ for AIRM)
- **Disk:** 30GB free space for Docker images and storage

### Estimated Resource Usage

**Minimal configuration (without AIRM):**
- **Control plane:** ~1GB memory, 1 CPU
- **ArgoCD:** ~500MB memory
- **Gitea + PostgreSQL:** ~1GB memory
- **OpenBao:** ~256MB memory
- **MinIO:** ~1GB memory (as configured)
- **Other components:** ~2-3GB memory

Total: ~6-8GB memory usage

**With AIRM enabled (full stack):**
- All of the above plus:
- **Keycloak:** ~1GB memory
- **RabbitMQ:** ~512MB memory
- **PostgreSQL (CNPG):** ~512MB memory
- **Kyverno:** ~500MB memory
- **Cluster-auth:** ~256MB memory
- **Kaiwo:** ~512MB memory
- **AIRM services:** ~2-3GB memory
- **Monitoring (OpenTelemetry):** ~500MB memory

Total: ~12-14GB memory usage

**Note:** Running the full AIRM stack on a single-node Kind cluster may require significant system resources and may not be suitable for laptops with limited RAM/CPU.

## Development Workflow

### Making Changes

1. **Update configurations** in `root/values_local_kind.yaml` or component-specific values
2. **Commit changes** to your local Git branch
3. **Push to Gitea** (happens automatically during setup)
4. **Sync in ArgoCD** - Changes will be detected and applied automatically

### Testing Components

To test specific components:

```bash
# Add component to enabledApps in values_local_kind.yaml
# ArgoCD will detect and deploy it

# Or manually sync
kubectl get applications -n argocd
argocd app sync <app-name>
```

### Cleaning Up

```bash
# Remove specific application
argocd app delete <app-name>

# Remove all cluster-forge apps
argocd app delete -l app.kubernetes.io/part-of=cluster-forge

# Full cluster reset
kind delete cluster --name cluster-forge-local
```

## Advanced Configuration

### Custom Domain with /etc/hosts

For a more realistic setup with custom domains:

```bash
# Add to /etc/hosts
sudo bash -c 'cat >> /etc/hosts << EOF
127.0.0.1 argocd.local.dev
127.0.0.1 gitea.local.dev
127.0.0.1 minio.local.dev
EOF'

# Run setup with custom domain
./scripts/setup-local-dev.sh local.dev

# Access via custom domains (still need port-forwarding)
```

### Multi-Node Cluster

For testing distributed scenarios:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
```

### Persistent Storage

To preserve data between cluster recreations:

```bash
# Use Docker volumes for persistence
docker volume create kind-storage

# Reference in kind config extraMounts
```

## Next Steps

- **Explore ArgoCD UI** to understand the GitOps workflow
- **Review component configurations** in the `sources/` directory
- **Enable additional components** as needed for your use case
- **Experiment with customizations** to understand the architecture
- **Check the main README.md** for production deployment guidelines

## References

- [Kind Documentation](https://kind.sigs.k8s.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Cluster-Forge Bootstrap Guide](../scripts/bootstrap.md)
- [Main README](../README.md)
