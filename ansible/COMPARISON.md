# Bootstrap Methods Comparison

This document compares the two bootstrap methods available for ClusterForge.

## Overview

| Feature | bash (bootstrap.sh) | Ansible (bootstrap.yml) |
|---------|---------------------|-------------------------|
| **Location** | Must run from repo | Can run from anywhere |
| **Repository** | Requires full clone | Clones automatically (shallow) |
| **Dependencies** | kubectl, helm, yq, openssl | Same + ansible |
| **Idempotency** | Partial | Full |
| **Error Handling** | Manual checks | Built-in retry/recovery |
| **Output** | Echo statements | Structured task output |
| **Configuration** | Command-line only | CLI + files + defaults |
| **Modularity** | Single file | Multiple task files |
| **Testing** | Limited | Dry-run/check mode |

## When to Use Each

### Use `scripts/bootstrap.sh` when:

- ✅ You already have the repository cloned
- ✅ You prefer a single bash script
- ✅ You don't want to install Ansible
- ✅ Quick one-off bootstrap
- ✅ Minimal dependencies required

### Use `ansible/bootstrap.yml` when:

- ✅ You want to run from outside the repository
- ✅ You manage multiple clusters
- ✅ You need configuration file management
- ✅ You want better error recovery
- ✅ You're familiar with Ansible
- ✅ You need CI/CD integration
- ✅ You want structured, repeatable deployments

## Command Comparison

### Basic Bootstrap

```bash
# Bash
cd cluster-forge
./scripts/bootstrap.sh example.com

# Ansible (from anywhere)
ansible-playbook ansible/bootstrap.yml -e cluster_domain=example.com
```

### With Cluster Size

```bash
# Bash
./scripts/bootstrap.sh example.com --cluster-size=large

# Ansible
ansible-playbook bootstrap.yml -e cluster_domain=example.com -e cluster_size=large
```

### Disable Apps

```bash
# Bash
./scripts/bootstrap.sh example.com --disabled-apps=airm,kaiwo*

# Ansible
ansible-playbook bootstrap.yml -e cluster_domain=example.com -e disabled_apps="airm,kaiwo*"
```

### AIWB-Only

```bash
# Bash
./scripts/bootstrap.sh example.com --aiwb-only

# Ansible
ansible-playbook bootstrap.yml -e cluster_domain=example.com -e aiwb_only=true
```

## Feature Parity

The Ansible playbook provides **100% feature parity** with bootstrap.sh:

| Feature | bash | Ansible | Notes |
|---------|------|---------|-------|
| Dependency checking | ✅ | ✅ | Ansible adds ansible itself |
| Cluster size selection | ✅ | ✅ | small/medium/large |
| Target revision | ✅ | ✅ | Tags, branches, commits |
| Specific apps | ✅ | ✅ | Via --apps/apps parameter |
| Disabled apps | ✅ | ✅ | Supports wildcards |
| AIWB-only mode | ✅ | ✅ | |
| Template-only mode | ✅ | ✅ | Dry-run output |
| Skip deps check | ✅ | ✅ | |
| Custom AIRM repo | ✅ | ✅ | |
| ArgoCD bootstrap | ✅ | ✅ | |
| OpenBao bootstrap | ✅ | ✅ | |
| Gitea bootstrap | ✅ | ✅ | |
| ClusterForge app | ✅ | ✅ | |
| Job monitoring | ✅ | ✅ | Ansible shows task status |
| Early failure detection | ✅ | ✅ | |

## Workflow Differences

### Bash Workflow

```
┌─────────────────────┐
│ Clone repository    │
│ (full history)      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ cd to scripts/      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Run bootstrap.sh    │
│ with arguments      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Bootstrap complete  │
└─────────────────────┘
```

### Ansible Workflow

```
┌─────────────────────┐
│ Optional: Get       │
│ ansible/ directory  │
│ (or use installer)  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Run playbook or     │
│ helper script       │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Ansible clones repo │
│ (shallow, auto)     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Bootstrap execution │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ Optional cleanup    │
└─────────────────────┘
```

## Configuration Management

### Bash

Configuration via command line only:

```bash
./scripts/bootstrap.sh example.com \
  --cluster-size=large \
  --target-revision=v2.0.4 \
  --disabled-apps=airm
```

### Ansible

Configuration via:

1. **Command line** (same as bash):
   ```bash
   ansible-playbook bootstrap.yml -e cluster_domain=example.com -e cluster_size=large
   ```

2. **Configuration files**:
   ```bash
   # Create config file
   cat > production.yml <<EOF
   cluster_domain: prod.example.com
   cluster_size: large
   disabled_apps: airm,kaiwo*
   EOF
   
   # Use config
   ansible-playbook bootstrap.yml -e @production.yml
   ```

3. **Helper script**:
   ```bash
   ./run-bootstrap.sh example.com --cluster-size large
   ```

4. **Makefile**:
   ```bash
   make bootstrap DOMAIN=example.com CLUSTER_SIZE=large
   ```

## Error Handling

### Bash

```bash
# Simple error handling
if ! kubectl wait --for=condition=complete job/gitea-init-job; then
  echo "ERROR: Job failed"
  exit 1
fi
```

### Ansible

```yaml
# Structured error handling with automatic retry
- name: Wait for job
  command: kubectl wait --for=condition=complete job/gitea-init-job
  retries: 3
  delay: 10
  register: result
  until: result.rc == 0
```

## Output Comparison

### Bash Output

```
=== Checking Dependencies ===
  ✓ kubectl      /usr/local/bin/kubectl (v1.28.0)
  ✓ helm         /usr/local/bin/helm (v3.12.0)
=== ClusterForge Bootstrap ===
Domain: example.com
=== ArgoCD Bootstrap ===
statefulset.apps/argocd-application-controller condition met
```

### Ansible Output

```
PLAY [Bootstrap ClusterForge] **************************************************

TASK [Validate required variables] ********************************************
ok: [localhost]

TASK [Bootstrap ArgoCD] *******************************************************
changed: [localhost]

TASK [Wait for ArgoCD components to be ready] *********************************
ok: [localhost]

PLAY RECAP ********************************************************************
localhost                  : ok=15   changed=5    unreachable=0    failed=0
```

## CI/CD Integration

### Bash in GitLab CI

```yaml
bootstrap:
  script:
    - git clone https://github.com/org/cluster-forge.git
    - cd cluster-forge
    - ./scripts/bootstrap.sh ${DOMAIN} --cluster-size=${SIZE}
```

### Ansible in GitLab CI

```yaml
bootstrap:
  image: cytopia/ansible:latest
  before_script:
    - ansible-galaxy collection install -r ansible/requirements.yml
  script:
    - ansible-playbook ansible/bootstrap.yml
        -e cluster_domain=${DOMAIN}
        -e cluster_size=${SIZE}
        -e cluster_forge_repo=${CI_REPOSITORY_URL}
```

## Maintenance

| Aspect | bash | Ansible |
|--------|------|---------|
| Single file | ✅ Easier to read | ❌ Multiple files |
| Modularity | ❌ Everything in one file | ✅ Separated by component |
| Testing | ❌ Manual testing | ✅ Ansible check/diff mode |
| Reusability | ❌ Hard to extract parts | ✅ Tasks can be reused |
| Version control | ✅ Simple | ✅ Structured |

## Migration Path

### From bash to Ansible

No migration needed! Both can coexist. To try Ansible:

```bash
# While still in the repo, test Ansible bootstrap
cd ansible
ansible-playbook bootstrap.yml -e cluster_domain=test.example.com

# If satisfied, use Ansible going forward
# Keep using bash bootstrap for existing workflows
```

### Command Translation

```bash
# Bash command
./scripts/bootstrap.sh example.com --cluster-size=large --disabled-apps=airm

# Equivalent Ansible
ansible-playbook ansible/bootstrap.yml \
  -e cluster_domain=example.com \
  -e cluster_size=large \
  -e disabled_apps=airm
```

## Performance

| Metric | bash | Ansible | Notes |
|--------|------|---------|-------|
| Startup time | ~1s | ~3s | Ansible initialization overhead |
| Execution time | ~5-10min | ~5-10min | Same (both run kubectl/helm) |
| Resource usage | Minimal | Slightly higher | Ansible Python process |
| Parallelization | Sequential | Potential | Ansible can parallelize tasks |

## Recommendations

### For New Users

**Start with bash** (`bootstrap.sh`):
- Simpler to understand
- Fewer dependencies
- Quick to get started

**Consider Ansible later** if you:
- Manage multiple clusters
- Want configuration file management
- Need better automation

### For Production

**Use Ansible** (`bootstrap.yml`):
- Better for CI/CD pipelines
- Configuration file management
- More robust error handling
- Easier to maintain multiple cluster configs

### For Development

**Either works fine**:
- bash: Faster iteration
- Ansible: Better testing with check mode

## Summary

Both methods are fully supported and maintained. Choose based on your needs:

- **bash**: Simple, minimal dependencies, quick one-off bootstraps
- **Ansible**: Robust, configurable, better for production/multiple clusters

The Ansible playbook is a **superset** of bash functionality - it can do everything bash does, plus more sophisticated configuration management and error handling.
