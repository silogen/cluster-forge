# ClusterForge Ansible Bootstrap

This directory contains an Ansible playbook to bootstrap ClusterForge clusters. The playbook is designed to run **outside** the cluster-forge repository and will automatically clone the repository (without history) to obtain the necessary init jobs and initial components.

## Overview

The Ansible bootstrap playbook provides the same functionality as the original `bootstrap.sh` script with these advantages:

- ✅ **Standalone execution**: Run from anywhere without needing the full repository
- ✅ **Cleaner separation**: Clone only what's needed for bootstrap
- ✅ **Better error handling**: Ansible's built-in retry and error handling
- ✅ **Idempotent**: Safe to run multiple times
- ✅ **Structured output**: Clear task progression and status
- ✅ **Variable management**: Easier to manage different cluster configurations

## Prerequisites

### Required Tools

The following tools must be installed on your system:

- **Ansible** (version >= 2.14)
  - Installation: [Ansible Installation Guide](https://docs.ansible.com/ansible/latest/installation_guide/)
- **kubectl** - Kubernetes CLI
  - Installation: https://kubernetes.io/docs/tasks/tools/install-kubectl/
- **helm** (version >= 3)
  - Installation: https://helm.sh/docs/intro/install/
- **yq** (version >= 4)
  - Installation: https://github.com/mikefarah/yq#install
- **openssl** - For password generation
  - Usually pre-installed on most systems
- **git** - For cloning the repository
  - Usually pre-installed or available via package manager

### Ansible Collections

Install required Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

This will install:
- `kubernetes.core` - For Kubernetes resource management
- `ansible.posix` - For POSIX utilities
- `community.general` - For general utilities

### Kubernetes Cluster

You must have:
- A running Kubernetes cluster (1.28+)
- `kubectl` configured to access the cluster
- Sufficient permissions to create namespaces and deploy applications

## Quick Start

### 1. Install Dependencies

```bash
# Install Ansible (Ubuntu/Debian)
sudo apt update
sudo apt install ansible

# Install Ansible (macOS)
brew install ansible

# Install Ansible collections
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure Your Cluster

Create a variables file (or copy from examples):

```bash
cp vars/example.yml vars/my-cluster.yml
```

Edit `vars/my-cluster.yml` and set at minimum:

```yaml
cluster_domain: "your-domain.com"
cluster_forge_repo: "https://github.com/yourusername/cluster-forge.git"
```

### 3. Run the Bootstrap

```bash
# Using a variables file
ansible-playbook bootstrap.yml -e @vars/my-cluster.yml

# Or pass variables directly
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e cluster_size=medium \
  -e cluster_forge_repo=https://github.com/myorg/cluster-forge.git
```

## Configuration

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `cluster_domain` | Domain for the cluster | `example.com` or `192.168.1.100.nip.io` |
| `cluster_forge_repo` | Git repository URL | `https://github.com/user/cluster-forge.git` |

### Cluster Size Behavior

The bootstrap behavior varies based on cluster size:

| Size | Gitea Deployed | Git Repository | Use Case |
|------|----------------|----------------|----------|
| **small** | ❌ No | External (GitHub/GitLab) | Development, testing, resource-constrained environments |
| **medium** | ✅ Yes | Local Gitea instance | Team production, self-contained |
| **large** | ✅ Yes | Local Gitea instance | Enterprise scale, self-contained |

**Small Cluster Optimization:**
- Skips Gitea deployment to reduce resource usage
- Points ClusterForge directly to external Git repository (GitHub, GitLab, etc.)
- Uses `cluster_forge_repo` and `target_revision` directly
- Ideal for development environments and resource-constrained clusters

**Medium/Large Clusters:**
- Deploys local Gitea instance
- Creates internal cluster-forge and cluster-values repositories
- Self-contained GitOps workflow
- No external dependencies after bootstrap

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_size` | `medium` | Cluster size: `small`, `medium`, or `large` |
| `cluster_forge_target_revision` | `v2.0.4` | Git tag, branch, or commit to use |
| `kube_version` | `1.33` | Kubernetes version for Helm templates |
| `clone_dir` | `~/.cluster-forge-bootstrap` | Where to clone the repository |
| `apps` | ` ` (empty) | Comma-separated list of apps to deploy |
| `disabled_apps` | ` ` (empty) | Comma-separated list of apps to disable (supports wildcards) |
| `aiwb_only` | `false` | Enable AIWB-only mode (disables AIRM/Kaiwo) |
| `airm_image_repository` | ` ` (empty) | Custom AIRM image repository |
| `template_only` | `false` | Only generate YAML without applying |
| `skip_dependency_check` | `false` | Skip dependency verification |
| `cleanup_clone` | `false` | Remove cloned repo after bootstrap |

## Usage Examples

### Basic Bootstrap

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=prod.example.com \
  -e cluster_size=large
```

### Small Cluster

```bash
ansible-playbook bootstrap.yml -e @vars/small-cluster.yml
```

### AIWB-Only Deployment

```bash
ansible-playbook bootstrap.yml -e @vars/aiwb-only.yml
```

### Development/Testing

```bash
ansible-playbook bootstrap.yml -e @vars/development.yml
```

### Disable Specific Apps

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e "disabled_apps=airm,airm-infra-*,prometheus-operator-crds"
```

### Deploy Specific Apps Only

```bash
# Deploy only OpenBao
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e apps=openbao

# Deploy multiple specific apps
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e apps=argocd,openbao,gitea,cluster-forge
```

### Template-Only Mode (Dry Run)

Generate YAML manifests without applying:

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e template_only=true
```

### Use Different Git Revision

```bash
# Use a specific tag
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e cluster_forge_target_revision=v2.0.3

# Use a branch
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e cluster_forge_target_revision=feature-branch

# Use a commit hash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e cluster_forge_target_revision=abc123def
```

## Advanced Usage

### Custom Clone Directory

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e clone_dir=/tmp/my-cluster-bootstrap
```

### Skip Dependency Check

Not recommended, but useful in CI/CD where dependencies are known:

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e skip_dependency_check=true
```

### Cleanup After Bootstrap

Automatically remove the cloned repository:

```bash
ansible-playbook bootstrap.yml \
  -e cluster_domain=example.com \
  -e cleanup_clone=true
```

## Bootstrap Process

The playbook performs the following steps in order:

1. **Pre-checks**
   - Validates required variables
   - Checks for required dependencies
   - Displays bootstrap configuration

2. **Repository Clone**
   - Clones cluster-forge repository (shallow, depth=1)
   - Checks out specified target revision

3. **Namespace Creation**
   - Creates `argocd`, `cf-gitea`, and `cf-openbao` namespaces

4. **ArgoCD Bootstrap**
   - Extracts ArgoCD configuration from values files
   - Deploys ArgoCD using Helm templates
   - Waits for all ArgoCD components to be ready

5. **OpenBao Bootstrap**
   - Extracts OpenBao configuration from values files
   - Deploys OpenBao using Helm templates
   - Runs OpenBao initialization job
   - Waits for initialization to complete

6. **Gitea Bootstrap**
   - Extracts Gitea configuration from values files
   - Creates ConfigMaps and Secrets
   - Deploys Gitea using Helm templates
   - Runs Gitea initialization job (creates repositories, pushes values)
   - Waits for initialization to complete

7. **ClusterForge Application**
   - Creates ArgoCD Application for ClusterForge
   - ArgoCD will sync remaining apps based on enabled/disabled configuration

8. **Cleanup** (optional)
   - Removes cloned repository if `cleanup_clone=true`

## Troubleshooting

### Dependency Check Failures

If dependencies are missing, install them before running:

```bash
# Example for Ubuntu/Debian
sudo apt install kubectl helm
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

### Git Clone Failures

Ensure you have access to the repository:

```bash
# Test git access
git clone --depth 1 https://github.com/yourusername/cluster-forge.git /tmp/test-clone
rm -rf /tmp/test-clone
```

### Kubectl Context Issues

Verify kubectl is configured correctly:

```bash
kubectl cluster-info
kubectl get nodes
```

### Job Failures

Check job logs if Gitea or OpenBao init jobs fail:

```bash
# OpenBao init job
kubectl logs job/openbao-init-job -n cf-openbao

# Gitea init job
kubectl logs job/gitea-init-job -n cf-gitea
```

### Re-running Bootstrap

The playbook is idempotent and can be safely re-run. Completed jobs will be skipped if already successful.

## Differences from bootstrap.sh

The Ansible playbook provides the same functionality as `scripts/bootstrap.sh` with these changes:

- **Repository cloning**: Automatically clones the repo instead of running from within it
- **Variable naming**: Uses Ansible variable naming conventions (underscores instead of uppercase)
- **Error handling**: Better structured error handling and retry logic
- **Output format**: Ansible's task-based output instead of bash echo statements
- **Modularity**: Split into separate task files for easier maintenance

### Variable Mapping

| bootstrap.sh | Ansible Playbook |
|-------------|------------------|
| `DOMAIN` | `cluster_domain` |
| `CLUSTER_SIZE` | `cluster_size` |
| `TARGET_REVISION` | `cluster_forge_target_revision` |
| `APPS` | `apps` |
| `DISABLED_APPS` | `disabled_apps` |
| `AIWB_ONLY` | `aiwb_only` |
| `TEMPLATE_ONLY` | `template_only` |
| `SKIP_DEPENDENCY_CHECK` | `skip_dependency_check` |

## File Structure

```
ansible/
├── ansible.cfg                 # Ansible configuration
├── bootstrap.yml               # Main playbook
├── inventory                   # Inventory file (localhost)
├── requirements.yml           # Ansible collection requirements
├── tasks/                     # Task files
│   ├── bootstrap_argocd.yml
│   ├── bootstrap_openbao.yml
│   ├── bootstrap_gitea.yml
│   └── create_cluster_forge_app.yml
└── vars/                      # Example variable files
    ├── example.yml            # Template with all options
    ├── small-cluster.yml      # Small cluster example
    ├── aiwb-only.yml         # AIWB-only example
    └── development.yml        # Development example
```

## Migration from bootstrap.sh

To migrate from using `bootstrap.sh` to the Ansible playbook:

1. **Install Ansible and dependencies** (see Prerequisites)

2. **Convert your bootstrap.sh command** to Ansible variables:

   ```bash
   # Old
   ./scripts/bootstrap.sh example.com --cluster-size=large --disabled-apps=airm

   # New
   ansible-playbook ansible/bootstrap.yml \
     -e cluster_domain=example.com \
     -e cluster_size=large \
     -e disabled_apps=airm
   ```

3. **Create a variables file** for your cluster configuration (recommended):

   ```bash
   cp ansible/vars/example.yml ansible/vars/my-cluster.yml
   # Edit my-cluster.yml
   ansible-playbook ansible/bootstrap.yml -e @ansible/vars/my-cluster.yml
   ```

## Support

For issues or questions:

1. Check this README and the example configurations
2. Review the task files in `tasks/` for implementation details
3. Run with `-vvv` for verbose output: `ansible-playbook bootstrap.yml -e @vars/my-cluster.yml -vvv`
4. Open an issue in the cluster-forge repository

## License

Same license as the parent ClusterForge project.
