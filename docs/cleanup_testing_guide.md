# Cluster Cleanup and Testing Guide

## Quick Reference

### Safe Testing Workflow

1. **Preview what will be deleted** (Dry Run)
   ```bash
   ./scripts/clean-cluster.sh --dry-run
   ```

2. **Clean the cluster** (keeps CRDs and namespaces for faster reinstall)
   ```bash
   ./scripts/clean-cluster.sh
   ```

3. **Fresh install with updated configuration**
   ```bash
   helm install cluster-forge ./root -n argocd -f ./root/values_small.yaml
   ```

4. **Monitor installation**
   ```bash
   watch kubectl get applications -n argocd
   ```

### Cleanup Script Options

| Option | Description | Use Case |
|--------|-------------|----------|
| `--dry-run` | Preview changes without deleting | Always run first! |
| `--force` | Skip confirmation prompts | Automation/CI |
| `--delete-crds` | Remove all CRDs | Complete reset (slower reinstall) |
| `--delete-namespaces` | Delete all CF namespaces | Full cleanup |
| `--verbose` | Show detailed command output | Debugging |

### Common Scenarios

#### Scenario 1: Quick Test (Recommended)
Fast iteration for configuration testing. Keeps CRDs to speed up reinstall.

```bash
# Clean up
./scripts/clean-cluster.sh -f

# Wait a moment
sleep 10

# Reinstall
helm install cluster-forge ./root -n argocd -f ./root/values_small.yaml
```

#### Scenario 2: Full Reset
Complete cluster reset including CRDs and namespaces.

```bash
# Preview first
./scripts/clean-cluster.sh --dry-run --delete-crds --delete-namespaces

# Full cleanup
./scripts/clean-cluster.sh --delete-crds --delete-namespaces

# Reinstall
helm install cluster-forge ./root -n argocd -f ./root/values_small.yaml
```

#### Scenario 3: Safe Interactive Cleanup
Review each step with confirmations.

```bash
# Interactive mode with detailed output
./scripts/clean-cluster.sh --verbose
```

### What Gets Deleted

**Always Deleted:**
- ArgoCD Applications (cluster-forge, cluster-apps)
- All managed application resources
- Persistent Volume Claims (⚠️ **DATA LOSS**)
- Pods, Services, Deployments, etc.
- Cluster Roles and Bindings

**Optional (with flags):**
- Custom Resource Definitions (`--delete-crds`)
- Namespaces (`--delete-namespaces`)

### Monitoring Cleanup Progress

```bash
# Watch ArgoCD applications
watch kubectl get applications -n argocd

# Check namespaces
kubectl get namespaces | grep -E '^cf-|^cluster-'

# Check PVCs
kubectl get pvc -A

# Check remaining resources
kubectl get all -A | grep -E '^cf-|^cluster-'
```

### Verifying Successful Cleanup

```bash
# Should show no cluster-forge applications
kubectl get applications -n argocd

# Should show no cf-* namespaces (if --delete-namespaces used)
kubectl get namespaces | grep cf-

# Check node resources freed up
kubectl describe node | grep -A 10 "Allocated resources"
```

### Testing the Gitea Removal

After reinstalling with the updated `values_small.yaml`:

1. **Verify Gitea is not installed:**
   ```bash
   kubectl get pods -A | grep gitea
   # Should return nothing
   ```

2. **Check memory allocation improved:**
   ```bash
   kubectl describe node | grep -A 10 "Allocated resources"
   # Memory requests should be lower than before (~81% instead of 83.7%)
   ```

3. **Verify application count:**
   ```bash
   kubectl get applications -n argocd | wc -l
   # Should show 57 apps instead of 59
   ```

4. **Check that other apps still work:**
   ```bash
   # ArgoCD should be healthy
   kubectl get pods -n argocd
   
   # MinIO should be healthy
   kubectl get pods -n cf-minio-tenant
   
   # Check overall health
   kubectl get applications -n argocd -o json | \
     jq -r '.items[] | "\(.metadata.name): \(.status.health.status)"'
   ```

### Troubleshooting

#### Stuck Namespaces
```bash
# Force delete stuck namespace
kubectl get namespace cf-gitea -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/cf-gitea/finalize" -f -
```

#### Stuck Applications
```bash
# Remove finalizers from stuck application
kubectl patch application cluster-forge -n argocd \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

#### Check What's Using Resources
```bash
# Top memory consumers
kubectl top pods -A --sort-by=memory | head -20

# Top CPU consumers  
kubectl top pods -A --sort-by=cpu | head -20
```

### Safety Notes

⚠️ **WARNING: DATA LOSS**
- Deleting PVCs will permanently delete all data
- Database data (PostgreSQL, etc.) will be lost
- MinIO buckets and objects will be lost
- Backup important data before cleanup

✅ **Safe for Testing:**
- Development/test clusters
- Disposable environments
- When testing configuration changes

❌ **NOT Safe for:**
- Production clusters
- Clusters with important data
- Without backups

### Expected Timeline

| Operation | Time | Notes |
|-----------|------|-------|
| Dry run | <5s | Just previews |
| Cleanup (keep CRDs) | 1-2 min | Fastest option |
| Cleanup (delete CRDs) | 2-5 min | Full cleanup |
| Fresh install | 10-20 min | Depends on images |
| Full sync | 20-40 min | All apps healthy |

### Post-Cleanup Resource Savings

After removing Gitea and cleaning up:

| Resource | Before | After Gitea Removal | Savings |
|----------|--------|---------------------|---------|
| Memory Requests | 20088Mi (83.7%) | ~19704Mi (~81.1%) | ~384Mi |
| CPU Requests | 9830m (61.4%) | ~9530m (~59.6%) | ~300m |
| Application Count | 59 | 57 | -2 |

After full optimization (with MinIO/Prometheus changes from Task 3):
- Expected memory: ~18.5Gi (76-78%)
- Expected savings: ~1.4-1.9Gi total
