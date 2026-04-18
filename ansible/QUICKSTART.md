# ClusterForge Ansible Bootstrap - Quick Start

Get your ClusterForge cluster up and running in minutes!

## Prerequisites Check

```bash
# Verify you have the required tools
which ansible kubectl helm yq openssl git

# Expected: paths to each tool
# If any are missing, see installation instructions below
```

## 5-Minute Setup

### 1. Install Ansible (if needed)

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y ansible

# macOS
brew install ansible

# RHEL/CentOS
sudo yum install -y ansible

# Fedora
sudo dnf install -y ansible
```

### 2. Install Ansible Collections

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 3. Run Bootstrap

**Option A: Simple one-liner (recommended for first-time users)**

```bash
./run-bootstrap.sh your-domain.com
```

**Option B: Full ansible-playbook command**

```bash
ansible-playbook bootstrap.yml -e cluster_domain=your-domain.com
```

**Option C: Use configuration file**

```bash
# Copy example config
cp vars/example.yml vars/my-cluster.yml

# Edit your config
nano vars/my-cluster.yml

# Run with config
ansible-playbook bootstrap.yml -e @vars/my-cluster.yml
```

## Common Scenarios

### Small Development Cluster

```bash
./run-bootstrap.sh dev.example.com --cluster-size small
```

### Production Cluster with IP Address

```bash
./run-bootstrap.sh 192.168.1.100.nip.io --cluster-size large
```

### AIWB-Only Deployment

```bash
./run-bootstrap.sh aiwb.example.com --aiwb-only
```

### Deploy with Specific Git Tag

```bash
./run-bootstrap.sh example.com --target-revision v2.0.3
```

### Disable Certain Apps

```bash
./run-bootstrap.sh example.com --disabled-apps "airm,kaiwo*,prometheus-operator-crds"
```

## What Happens During Bootstrap?

1. ✅ **Dependency check** - Verifies kubectl, helm, yq, etc.
2. 📦 **Repository clone** - Shallow clone of cluster-forge (no history)
3. 🏗️ **Namespace creation** - Creates argocd, cf-gitea, cf-openbao
4. 🚀 **ArgoCD deployment** - Installs and waits for ArgoCD
5. 🔐 **OpenBao deployment** - Installs secrets manager and runs init job
6. 📚 **Gitea deployment** - Installs git server and pushes cluster values
7. 📋 **ClusterForge app** - Creates parent ArgoCD application
8. ⚡ **ArgoCD sync** - ArgoCD deploys remaining apps automatically

**Total time**: Approximately 3-10 minutes depending on cluster resources

## Verify Installation

```bash
# Check all pods are running
kubectl get pods -A

# Check ArgoCD applications
kubectl get applications -n argocd

# Access ArgoCD UI (get admin password)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Next Steps

After bootstrap completes:

1. **Access ArgoCD**: https://argocd.your-domain.com
   - Username: `admin`
   - Password: Get from secret above

2. **Access Gitea**: https://gitea.your-domain.com
   - Username: `silogen-admin`
   - Password: Stored in `gitea-admin-credentials` secret

3. **Monitor Sync**: Watch ArgoCD sync all applications
   ```bash
   kubectl get applications -n argocd -w
   ```

4. **Verify Health**: Check application status
   ```bash
   kubectl get applications -n argocd -o wide
   ```

## Troubleshooting

### "command not found" errors

Install missing dependencies:

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

### Job failures

Check logs:

```bash
# OpenBao init job
kubectl logs job/openbao-init-job -n cf-openbao

# Gitea init job
kubectl logs job/gitea-init-job -n cf-gitea
```

### Permission errors

Ensure kubectl has cluster-admin access:

```bash
kubectl auth can-i create namespaces
# Should return "yes"
```

### Re-run bootstrap

The bootstrap is idempotent - safe to run multiple times:

```bash
# Will skip already-completed jobs
./run-bootstrap.sh your-domain.com
```

## Configuration Files

For repeated use, create a configuration file:

```bash
# Create config
cat > vars/production.yml <<EOF
cluster_domain: "prod.example.com"
cluster_size: "large"
cluster_forge_repo: "https://github.com/myorg/cluster-forge.git"
cluster_forge_target_revision: "v2.0.4"
disabled_apps: "kedify-otel"
EOF

# Use config
ansible-playbook bootstrap.yml -e @vars/production.yml
```

## Help & Support

```bash
# Show helper script options
./run-bootstrap.sh --help

# Verbose mode for debugging
./run-bootstrap.sh your-domain.com --verbose

# Full documentation
cat README.md
```

## Clean Up (if needed)

To remove everything:

```bash
# Delete all namespaces
kubectl delete namespace argocd cf-gitea cf-openbao

# Delete ClusterForge applications
kubectl delete application cluster-forge -n argocd
```

---

**Need more details?** See [README.md](README.md) for complete documentation.

**Questions?** Open an issue in the cluster-forge repository.
