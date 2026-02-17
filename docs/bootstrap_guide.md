# Bootstrap Guide

This guide explains how to bootstrap a complete GitOps environment using Cluster-Forge's three-phase deployment model. The bootstrap process establishes ArgoCD, OpenBao (secret management), and Gitea (Git repository) before deploying the full application stack.

## Prerequisites

- Kubernetes cluster (1.33+ recommended, running and accessible via `kubectl`)
- Tools installed:
  - `kubectl` with cluster-admin access
  - `helm` (3.0+)
  - `openssl` (for password generation)
  - `yq` (v4+)
  - `git` (for --dev mode)

## Usage

```bash
./scripts/bootstrap.sh <domain> [--CLUSTER_SIZE=small|medium|large] [--dev]
```

### Arguments

- **domain** (required): Cluster domain for all services (e.g., `example.com`, `192.168.1.100.nip.io`)

### Options

- **--CLUSTER_SIZE** `[small|medium|large]`: Cluster size configuration (default: `medium`)
- **--dev**: Enable development mode for feature branch testing
- **--help**, **-h**: Show usage information

### Examples

```bash
# Basic usage with default medium cluster size
./scripts/bootstrap.sh 192.168.1.100.nip.io

# Large cluster
./scripts/bootstrap.sh example.com --CLUSTER_SIZE=large

# Development mode for feature branch testing
./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small --dev
```

## How It Works

The bootstrap script uses a three-phase deployment model:

### Phase 1: Pre-Cleanup
- Detects previous installations by checking for completed gitea-init-job
- Removes Gitea resources to enable fresh deployment
- Deletes OpenBao initialization jobs and temporary files
- Ensures clean state for new bootstrap

### Phase 2: GitOps Foundation Bootstrap (Manual Helm Templates)

**1. Configuration Preparation**
- Validates required domain argument
- Validates cluster size (small, medium, or large)
- Merges base `values.yaml` with size-specific overrides `values_<size>.yaml`
- Sets `global.domain` and `global.clusterSize` in merged configuration
- In dev mode: prompts for git branch selection and configures targetRevision

**2. Namespace Creation**
Creates three namespaces for core components:
- `argocd` - GitOps controller
- `cf-gitea` - Git repository server
- `cf-openbao` - Secret management system

**3. ArgoCD Bootstrap**
- Extracts ArgoCD values from merged configuration
- Deploys ArgoCD using `helm template` with server-side apply
- Uses `--field-manager=argocd-controller` to match ArgoCD's self-management
- Waits for all ArgoCD components to be ready:
  - application-controller StatefulSet
  - applicationset-controller Deployment
  - redis Deployment
  - repo-server Deployment

**4. OpenBao Bootstrap**
- Extracts OpenBao values from merged configuration
- Deploys OpenBao using `helm template` with server-side apply
- Waits for `openbao-0` pod to be running
- Runs initialization job (`openbao-init-job`) which:
  - Initializes OpenBao Raft cluster
  - Unseals all pods (3 for large clusters with HA)
  - Configures Vault policies for each namespace
  - Creates Kubernetes auth method
  - Stores initialization keys and secrets

**5. Gitea Bootstrap**
- Generates random admin password using `openssl rand -hex 16`
- Creates `initial-cf-values` ConfigMap with merged configuration
- Creates `gitea-admin-credentials` secret
- Extracts Gitea values from merged configuration
- Deploys Gitea using `helm template`
- Waits for Gitea deployment to be ready
- Runs initialization job (`gitea-init-job`) which:
  - Creates admin API token
  - Creates `cluster-org` organization
  - Clones and pushes cluster-forge repository from initial-cf-values ConfigMap
  - Creates cluster-values repository with configuration
  - In dev mode: sets targetRevision to selected branch

### Phase 3: App-of-Apps Deployment (ArgoCD-Managed)

**6. ClusterForge Application Deployment**
- Renders root helm chart with merged configuration
- Creates `cluster-forge` Application resource in ArgoCD
- When `externalValues.enabled: true`, uses multi-source feature:
  - Source 1: cluster-forge repo (root/ helm chart)
  - Source 2: cluster-values repo (custom values.yaml)
- ArgoCD deploys all enabled applications based on configuration
- Applications deployed in wave order (-5 to 0) based on dependencies

**7. Cleanup**
- Removes temporary merged values files from /tmp/

## Cluster Configuration

### Values Files Structure

ClusterForge uses a layered configuration approach with YAML merge semantics:

1. **Base values** (`root/values.yaml`):
   - Contains all app definitions
   - Defines default configuration for all apps
   - Specifies `enabledApps` list (alpha-sorted)
   - Configured with:
     - `clusterForge.repoUrl` - Points to Gitea service URL (local mode) or GitHub (external mode)
     - `clusterForge.targetRevision` - Version/branch to deploy
     - `externalValues.enabled: true` - Enables dual-repository pattern
     - `externalValues.repoUrl` - Points to cluster-values repo in Gitea
     - `global.domain` - Set by bootstrap script
     - `global.clusterSize` - Set by bootstrap script

2. **Size-specific values** (`root/values_<size>.yaml`):
   - Override base values for specific cluster sizes
   - Define resource limits and requests
   - Single node (small and medium) RWO local-path storage
   - Multinode (large) RWX storage
   - Modify replica counts and HA settings
   - Add size-specific enabled apps (e.g., `kyverno-policies-storage-local-path` for small/medium)
   - Available sizes: `small`, `medium`, `large`
   - Uses DRY principle - only contains differences from base

3. **External values** (`cluster-values/values.yaml` in Gitea):
   - Created during bootstrap in the `cluster-values` repository
   - Contains cluster-specific overrides
   - Can be modified post-bootstrap for customizations
   - Structure:
     ```yaml
     clusterForge:
       repoURL: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git
       path: root
       targetRevision: main  # or feature branch in dev mode
     
     global:
       clusterSize: medium  # Set by --CLUSTER_SIZE flag
       domain: example.com  # Set by domain argument
     ```

### Value Merging Order

When ArgoCD renders the cluster-forge application, values are merged in this order (later values override earlier):

1. Base `values.yaml`
2. Size-specific `values_<size>.yaml`
3. External `cluster-values/values.yaml` from Gitea

### Cluster Sizes

Each cluster size is optimized for different resource constraints:

- **Small**: Development/testing environments, minimal resources
- **Medium** (default): Production-ready, balanced configuration
- **Large**: High-availability, maximum performance

Size-specific configurations typically adjust:
- Component replica counts (ArgoCD, PostgreSQL, etc.)
- Resource limits and requests (CPU, memory)
- Storage sizes (PVC, retention periods)
- High-availability features (Redis HA, multiple replicas)

## ClusterForge App-of-Apps Model

The bootstrap script creates the root `cluster-forge` Application in ArgoCD, which implements an app-of-apps pattern.

### Application Structure

The `cluster-forge` Application is defined in [root/templates/cluster-forge.yaml](../root/templates/cluster-forge.yaml):

### Child Applications

The root chart renders individual Application resources for each app listed in `enabledApps` using the template in [root/templates/cluster-apps.yaml](../root/templates/cluster-apps.yaml).

Each child application includes:
- **Namespace**: Target namespace for the application
- **Path**: Location of helm chart or manifests in `sources/<path>`
- **Values**: Configuration from `apps.<name>.valuesObject` or `valuesFile`
- **Sync wave**: Deployment order (lower numbers deploy first)
- **Sync policy**: Automated with prune and self-heal enabled
- **Ignore differences**: Optional resource-specific ignore rules

Example child application configuration in values:

```yaml
apps:
  argocd:
    path: argocd/8.3.5
    namespace: argocd
    syncWave: -3
    valuesObject:
      # ArgoCD-specific values
    helmParameters:
      - name: global.domain
        value: "argocd.{{ .Values.global.domain }}"
```

## Access to Main Components

1. **ArgoCD:**
   ```bash
   # Initial admin password
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   
   # Access URL (replace with your domain)
   echo "https://argocd.${DOMAIN}"
   ```

2. **Gitea:**
   ```bash
   # Admin username
   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath="{.data.username}" | base64 -d
   
   # Admin password
   kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath="{.data.password}" | base64 -d
   
   # API token (created by init job)
   kubectl -n cf-gitea get secret gitea-admin-token -o jsonpath="{.data.token}" | base64 -d
   
   # Access URL (replace with your domain)
   echo "https://gitea.${DOMAIN}"
   ```

3. **OpenBao:**
   ```bash
   # Root token
   kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.root_token}' | base64 -d
   
   # Unseal keys (stored in openbao-keys secret)
   kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.unseal_keys_b64}' | base64 -d
   ```

4. **Keycloak (deployed by ArgoCD):**
   ```bash
   # Admin password
   kubectl -n keycloak get secret keycloak-credentials -o jsonpath="{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}" | base64 -d
   
   # Dev user password
   kubectl -n keycloak get secret airm-devuser-credentials -o jsonpath="{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}" | base64 -d
   ```

## Development Mode

Development mode is designed for testing ClusterForge changes from a feature branch in a lightweight environment. Unlike production mode, dev mode uses a minimal configuration without local Gitea mirrors or full secret management infrastructure.

### Key Differences from Production

| Feature | Production Mode | Development Mode |
|---------|----------------|------------------|
| **Cluster Size** | Medium/Large recommended | **Small required** |
| **Repository Source** | Local Gitea mirrors | Direct GitHub access |
| **Gitea Deployment** | ✓ Deployed | ✗ **Not deployed** |
| **OpenBao Deployment** | ✓ Full deployment | ✗ **Minimal/not deployed** |
| **External Values** | ✓ Enabled (cluster-values repo) | ✗ Disabled (inline values) |
| **Resource Requirements** | Higher | **Minimal** |
| **Use Case** | Production clusters | Feature testing, development |

### Prerequisites for Dev Mode

1. **Small cluster configuration required** - Dev mode is optimized for resource-constrained environments
2. **GitHub access** - Direct connection to GitHub repository (no local Gitea mirror)
3. **Minimal infrastructure** - Skips Gitea and heavy secret management components

### Enabling Development Mode

**Note:** Dev mode must use small cluster size to work properly:

```bash
./bootstrap.sh --dev dev.example.com --CLUSTER_SIZE=small
```

The script will:
1. Detect your current git branch
2. Prompt you to confirm using it or specify a custom branch:
   ```
   Development mode enabled - ArgoCD will point to live GitHub repository
   Current git branch: feature-xyz
   
   Use current branch 'feature-xyz' for targetRevision? [Y/n/custom_branch]:
   ```
3. Configure ClusterForge to point directly to GitHub (bypassing Gitea)
4. Set `externalValues.enabled: false` to use inline configuration
5. Deploy only ArgoCD and essential components

### Development Workflow

1. **Create feature branch:**
   ```bash
   git checkout -b feature-xyz
   ```

2. **Make your changes** to apps, values, or configurations

3. **Commit and push to GitHub:**
   ```bash
   git add .
   git commit -m "Add new feature"
   git push origin feature-xyz
   ```

4. **Bootstrap cluster in dev mode (small cluster only):**
   ```bash
   ./bootstrap.sh --dev dev.example.com --CLUSTER_SIZE=small
   # Confirm using 'feature-xyz' branch when prompted
   ```

5. **Iterate:** Any subsequent changes pushed to `feature-xyz` will automatically sync to the cluster directly from GitHub via ArgoCD

### Configuration for Dev Mode

In dev mode, the cluster-forge Application uses a single-source configuration:

```yaml
externalValues:
  enabled: false  # No separate cluster-values repo

clusterForge:
  repoUrl: "https://github.com/silogen/cluster-forge.git"  # Direct GitHub access
  targetRevision: feature-xyz  # Your feature branch
```

This bypasses the need for:
- Local Gitea deployment and mirrors
- Separate cluster-values repository
- Full OpenBao secret management infrastructure

### When to Use Dev Mode

**Use dev mode when:**
- Testing new features or configurations
- Developing on resource-constrained clusters
- Rapid iteration without infrastructure overhead
- Working with feature branches before merging

**Use production mode when:**
- Deploying to production environments
- Requiring full secret management (OpenBao)
- Needing local Git mirrors for air-gapped scenarios
- Medium/Large cluster configurations

## Troubleshooting

**Note:** Some troubleshooting steps below only apply to production mode deployments that include Gitea and OpenBao.

### Bootstrap Fails at Gitea Init

*Production mode only*

If the Gitea initialization job fails during repository migration:

```bash
# Check job logs
kubectl logs -n cf-gitea job/gitea-init-job

# The job automatically retries migration up to 5 times
# If it continues failing, check Gitea pod logs
kubectl logs -n cf-gitea deploy/gitea -c gitea
```

### OpenBao Init Job Fails

*Production mode only*

If OpenBao initialization fails:

```bash
# Check init job logs
kubectl logs -n cf-openbao job/openbao-init-job

# Verify OpenBao is running
kubectl get pods -n cf-openbao

# Re-run bootstrap (pre-cleanup will handle the retry)
./bootstrap.sh your-domain.com
```

### ArgoCD Applications Not Syncing

If applications aren't deploying:

```bash
# Check cluster-forge app status
kubectl get application cluster-forge -n argocd -o yaml

# Check individual app status
kubectl get applications -n argocd

# View app details in ArgoCD UI
# https://argocd.your-domain.com
```

### Merged Values Inspection

The bootstrap script creates temporary merged values at `/tmp/merged_values.yaml` for debugging. You can inspect this file during bootstrap to see the final merged configuration.

## Post-Bootstrap Customization

### Production Mode (with Gitea)

After bootstrap completes in production mode, you can customize the cluster by modifying the `cluster-values` repository in Gitea:

1. **Access Gitea** at `https://gitea.${DOMAIN}`
2. **Navigate to** `cluster-org/cluster-values` repository
3. **Edit** `values.yaml` to add/override configuration
4. **Commit** changes
5. **ArgoCD** will automatically detect and apply changes

Example customizations in `cluster-values/values.yaml`:

```yaml
# Override app-specific values
apps:
  keycloak:
    valuesObject:
      replicas: 2
      resources:
        requests:
          memory: "1Gi"

# Disable specific apps
enabledApps:
  - argocd
  - gitea
  # ... list only apps you want enabled

# Add custom global values
global:
  myCustomValue: "something"
```

### Development Mode (without Gitea)

In development mode, there is no local Gitea repository. Customization is done by:

1. **Editing values files** in your local cluster-forge repository
2. **Committing changes** to your feature branch
3. **Pushing to GitHub:**
   ```bash
   git add root/values.yaml  # or values_small.yaml
   git commit -m "Update configuration"
   git push origin feature-xyz
   ```
4. **ArgoCD syncs automatically** from GitHub

Since `externalValues.enabled: false` in dev mode, all configuration is in the main values files (`values.yaml`, `values_small.yaml`).

## File Cleanup

The bootstrap script automatically cleans up temporary files at the end:
- `/tmp/merged_values.yaml`
- `/tmp/argocd_values.yaml`
- `/tmp/argocd_size_values.yaml`
- `/tmp/openbao_values.yaml`
- `/tmp/openbao_size_values.yaml`
- `/tmp/gitea_values.yaml`
- `/tmp/gitea_size_values.yaml`
 
