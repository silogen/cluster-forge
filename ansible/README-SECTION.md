# Bootstrap Options - Section for README.md

This content can be added to the main README.md to inform users about both bootstrap methods.

---

## 🚀 Bootstrap Options

Cluster-Forge provides two bootstrap methods to suit different workflows:

### Option 1: Bash Script (Quick & Simple)

Best for: Quick deployments, one-off clusters, minimal dependencies

```bash
# Clone repository first
git clone https://github.com/yourorg/cluster-forge.git
cd cluster-forge

# Run bootstrap
./scripts/bootstrap.sh example.com --cluster-size=medium
```

**Pros:**
- ✅ Minimal dependencies (kubectl, helm, yq, openssl)
- ✅ Single file, easy to understand
- ✅ Quick for one-off deployments

**See:** [Bootstrap Guide](docs/bootstrap_guide.md)

### Option 2: Ansible Playbook (Robust & Configurable)

Best for: Production, CI/CD, multiple clusters, configuration management

```bash
# Can run from anywhere - no repo clone needed!
# Ansible will clone automatically (without history)

# Quick start
cd ansible
ansible-playbook bootstrap.yml -e cluster_domain=example.com

# Or use helper script
./run-bootstrap.sh example.com --cluster-size=medium

# Or use configuration file
ansible-playbook bootstrap.yml -e @vars/production.yml
```

**Pros:**
- ✅ Run from anywhere (auto-clones repo)
- ✅ Configuration file support
- ✅ Better error handling
- ✅ Idempotent (safe to re-run)
- ✅ CI/CD friendly

**See:** [Ansible Bootstrap README](ansible/README.md) | [Quick Start](ansible/QUICKSTART.md) | [Comparison](ansible/COMPARISON.md)

### Which Should I Use?

| Use Case | Recommended Method |
|----------|-------------------|
| First-time user | **Bash** - simpler to get started |
| Production deployment | **Ansible** - better for production environments |
| Managing multiple clusters | **Ansible** - configuration file management |
| CI/CD pipeline | **Ansible** - better automation support |
| One-off testing | **Bash** - quicker for quick tests |
| Air-gapped environment | **Bash** - fewer moving parts |

**Both methods provide 100% feature parity** - choose based on your workflow preferences.

---

## Quick Command Reference

### Bash Examples
```bash
# Basic deployment
./scripts/bootstrap.sh example.com

# With cluster size
./scripts/bootstrap.sh example.com --cluster-size=large

# Disable specific apps
./scripts/bootstrap.sh example.com --disabled-apps=airm,kaiwo*

# AIWB-only mode
./scripts/bootstrap.sh example.com --aiwb-only

# Specific revision
./scripts/bootstrap.sh example.com --target-revision=v2.0.3
```

### Ansible Examples
```bash
# Basic deployment
ansible-playbook ansible/bootstrap.yml -e cluster_domain=example.com

# Using helper script
./ansible/run-bootstrap.sh example.com --cluster-size large

# Using configuration file
ansible-playbook ansible/bootstrap.yml -e @ansible/vars/my-cluster.yml

# Makefile
make -C ansible bootstrap DOMAIN=example.com

# Standalone installer (from anywhere)
bash <(curl -sfL https://raw.githubusercontent.com/.../ansible/install.sh) example.com
```

For complete documentation on either method, see:
- Bash: [docs/bootstrap_guide.md](docs/bootstrap_guide.md)
- Ansible: [ansible/README.md](ansible/README.md)
