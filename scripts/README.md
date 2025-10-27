# Cluster Forge V2 

This script bootstraps a complete GitOps environment with ArgoCD, OpenBao (secret management), and Gitea (Git repository) on a Kubernetes cluster.

## Prerequisites

- Kubernetes cluster (running and accessible via `kubectl`)
- Tools installed:
  - `kubectl`
  - `helm`
  - `yq`
  - `openssl`

## Usage

```bash
./bootstrap.sh <domain>
```

**Example:**
```bash
./bootstrap.sh plat-dev-1.silogen.ai
```

```
Additional Args:

  SKIP_LONGHORN_READINESS_CHECK=[true|false (deafult)]
    - bypass Longhorn readiness check, which will abort bootstrap.sh if it fails normally. Useful if not using Longhorn for pvc management.
```

## What Does It Do?

The script performs the following steps in sequence:

### 1. Domain Configuration
- Validates that a domain argument is provided
- Updates the global domain value in `../root/values_cf.yaml`
- This domain is used for all service endpoints (Gitea, ArgoCD, etc.)

### 2. Namespace Creation
Creates three namespaces for core components:
- `argocd` - GitOps controller
- `cf-gitea` - Git repository server
- `cf-openbao` - Secret management system

### 3. ArgoCD Bootstrap
- Deploys ArgoCD
- Waits for all ArgoCD components to be ready

### 4. OpenBao Bootstrap
- Deploys OpenBao
- Waits for the first pod (`openbao-0`) to be running
- Runs initialization job (`openbao-init-job`) which:
    - Initializes & configures OpenBao Raft cluster
    - Unseals all pods
    - Creates root credentials

### 5. Gitea Bootstrap
- Creates gitea-admin credentials secret
- Creates ConfigMap with initial cluster forge values
- Deploys & configures Gitea
- Waits for Gitea deployment to be ready
- Runs initialization job (`gitea-init-job`) which:
    - Creates cluster-org organization
    - Creates cluster-forge as a mirror repo
    - Creates cluster-values as a repo with cluster configuration

### 6. ArgoCD Application Deployment
- Creates root cluster-forge app that manages all other apps

## Access to main components

1. **ArgoCD:**
   ```bash
   # Initial admin user password
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```

2. **Gitea:**
   ```bash
   # Admin username
   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath="{.data.username}" | base64 -d
   
   # Admin password
   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath="{.data.password}" | base64 -d
   ```

3. **OpenBao:**
   ```bash
   # Root token
   kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.root_token}' | base64 -d
   ```

## Development

For development purposes there is a way to sync all apps directly from cluster-forge GitHub repo bypassing gitea. Here is the possible development flow: 

- Create feature-branch with your changes
- Modify `values_dev.yaml` file with the following parameters:
  - `clusterForge.targetRevision` - feature-branch name
  - `global.domain` - domain name
- Commit & push changes to your feature-branch
- Run `scripts/bootstrap_dev.sh`
- Wait for cluster apps to be ready
- From this point forward, any changes you push to your feature branch will be automatically synchronized to the cluster by ArgoCD.
 