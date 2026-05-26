# KGateway to Envoy-Gateway Migration Guide

## Overview

This guide helps cluster managers migrate from kgateway to envoy-gateway by upgrading cluster-forge from v2.0.5 to v2.0.6. The migration involves only **2 manual steps** and takes approximately **20-30 minutes**.

> **Important:** This migration will briefly affect gateway routing. Plan accordingly and notify your team.

## Prerequisites

Before starting, verify your cluster meets these requirements:

```bash
# Check MetalLB is deployed
kubectl get ipaddresspool cluster-bloom-ip-pool -n metallb-system

# Check current kgateway setup  
kubectl get secret cluster-tls -n kgateway-system
kubectl get svc -n kgateway-system

# Check ArgoCD access
kubectl get pods -n argocd
```

**Required Access:**
- kubectl admin permissions
- ArgoCD web UI access
- Current cluster-forge version v2.0.5

## Migration Process

### Step 1: Run Migration Job (5-10 minutes)

Apply the comprehensive migration job that handles both TLS secret migration and node labeling:

```bash
cd cluster-forge/scripts/utils
kubectl apply -f envoy-gateway-migration.yaml
```

Monitor the migration progress:

```bash
kubectl logs -f job/envoy-gateway-migration -n envoy-gateway-system
```

**Expected Output:**
```
🔧 Envoy-Gateway Migration Job Started
================================================

📋 Phase 1: TLS Secret Migration
✅ envoy-gateway-system namespace created/verified
✅ cluster-tls secret copied from kgateway-system
✅ Phase 1 Complete: TLS migration successful

📋 Phase 2: Node Labeling for Gateway Placement
✅ MetalLB IPAddressPool found
✅ Found MetalLB IP: 192.168.1.100
🎯 Target node identified: worker-node-1
✅ cluster-bloom/first-node=true label applied
✅ Phase 2 Complete: Node labeling successful

🚀 MIGRATION COMPLETE
```

⚠️ **If the job fails, see [Troubleshooting](#troubleshooting) section before proceeding.**
### Step 2: Update Cluster Configuration (7 minutes)

This step involves updating both Gitea and ArgoCD to complete the migration.

#### 2.1 Update cluster-values.yaml in Gitea (3-4 minutes)

First, update the cluster configuration file in Gitea.

**Navigate to Gitea:**
1. Open your browser and go to `https://gitea.<your-domain>`
2. Login with your credentials
3. Navigate to the `cluster-org/cluster-values` repository
4. Open the file: `values.yaml`
5. Click the **"Edit"** button (pencil icon)

**Make the following changes:**

**Change 1: Update targetRevision**

Find:
```yaml
targetRevision: v2.0.5
```

Change to:
```yaml
targetRevision: v2.0.6
```

**Change 2: Update enabledApps list**

In the `enabledApps:` section:

**Comment out** these apps (add `#` at the beginning):
```yaml
enabledApps:
  # - gateway-api           # ← Comment out
  # - kgateway              # ← Comment out
  # - kgateway-config       # ← Comment out
  # - kgateway-crds         # ← Comment out
```

**Add** these new apps:
```yaml
enabledApps:
  - envoy-gateway          # ← Add this
  - envoy-gateway-config   # ← Add this
```

**Complete example:**
```yaml
targetRevision: v2.0.6

enabledApps:
  # Old gateway apps (commented out for migration)
  # - gateway-api
  # - kgateway
  # - kgateway-config
  # - kgateway-crds

  # New gateway apps
  - envoy-gateway
  - envoy-gateway-config

  # Other apps (unchanged)
  - cert-manager
  - cert-manager-config
  - metallb
  - metallb-config
  # ... rest of your enabled apps
```

**Commit the changes:**
1. Scroll to the bottom of the edit page
2. Add commit message: `feat: migrate from kgateway to envoy-gateway v2.0.6`
3. Click **"Commit Changes"**

> **  Important:** After committing, the cluster-forge ArgoCD application will show as "OutOfSync" or "Degraded". This is expected and will be fixed in the next step.

#### 2.2 Update cluster-forge App in ArgoCD (2-3 minutes)

Now sync the ArgoCD application with the new configuration.

**Navigate to ArgoCD:**
1. Open your browser and go to `https://argocd.<your-domain>`
2. Login with your admin credentials

**Update the cluster-forge application:**
1. Click on the **"cluster-forge"** application
   - You should see it's **"OutOfSync"** - this is expected after the Gitea changes
2. Click **"APP DETAILS"** button (top right)
3. Click **"EDIT"** button
4. Find the **"Source"** section
5. Locate: **"Source 1: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git"**
6. Click the **"Edit"** button (pencil icon) for this source

**Update Target Revision:**
1. Find the **"TARGET REVISION"** field (currently showing `v2.0.5`)
2. Change to: `v2.0.6`
3. Click **"SAVE"** button
4. Click **"SAVE"** again on the main APP DETAILS dialog

**Sync the application:**
1. Click **"SYNC"** button (in the top toolbar)
2. Review the sync options (default settings are fine)
3. Click **"SYNCHRONIZE"** button
### Step 3: Monitor App Transition (5-10 minutes)

Watch ArgoCD as it automatically manages the application lifecycle:

**Apps Being Removed:**
- `gateway-api`
- `kgateway` 
- `kgateway-config`
- `kgateway-crds`

**Apps Being Created:**
- `envoy-gateway`
- `envoy-gateway-config`

**Wait for:** All new apps to reach **"Healthy"** and **"Synced"** status.

### Step 4: Clean Up Old Resources (3-5 minutes)

Remove the old kgateway resources to free up the LoadBalancer IP:

```bash
# Delete kgateway namespace (this removes all kgateway resources)
kubectl delete namespace kgateway-system

# Delete kgateway CRDs
kubectl delete crd gateways.gateway.kgateway.dev --ignore-not-found
kubectl delete crd gatewayextensions.gateway.kgateway.dev --ignore-not-found  
kubectl delete crd trafficpolicies.gateway.kgateway.dev --ignore-not-found

# Verify LoadBalancer IP is now assigned to envoy-gateway
kubectl get svc -n envoy-gateway-system -o wide
```

**Expected:** The envoy-gateway LoadBalancer service should now have an external IP.

## Validation

Verify the migration was successful:

### 1. Check envoy-gateway Status
```bash
# Verify envoy-gateway is running
kubectl get pods -n envoy-gateway-system

# Check gateway resource
kubectl get gateway https -n envoy-gateway-system

# Verify LoadBalancer service has IP
kubectl get svc envoy-gateway -n envoy-gateway-system
```

### 2. Test Application Access
```bash
# Test key applications are accessible
curl -k https://gitea.<your-domain>
curl -k https://argocd.<your-domain>
```

### 3. Validation Checklist

- [ ] `envoy-gateway-system` namespace exists
- [ ] `cluster-tls` secret exists in `envoy-gateway-system`
- [ ] First node has `cluster-bloom/first-node=true` label
- [ ] envoy-gateway pods are running and healthy
- [ ] `https` gateway resource is ready
- [ ] envoy-gateway LoadBalancer service has external IP
- [ ] Gitea is accessible via https
- [ ] ArgoCD is accessible via https
- [ ] All cluster applications are functional

## Troubleshooting

### Migration Job Issues

**Problem:** Migration job fails during TLS copy
```bash
# Check if source secret exists
kubectl get secret cluster-tls -n kgateway-system

# If missing, this is expected for new deployments
# The job will skip TLS copy and continue
```

**Problem:** Node labeling fails
```bash
# Check MetalLB configuration
kubectl describe ipaddresspool cluster-bloom-ip-pool -n metallb-system

# Verify node annotations
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.annotations}{"\n"}{end}' | grep -E '(provided-node-ip|node-address)'
```

### ArgoCD Issues

**Problem:** cluster-forge app stuck in "Progressing" state
- **Solution:** Click "Refresh" in ArgoCD UI, wait 5 minutes, then try "Hard Refresh"

**Problem:** Old apps won't disappear
- **Solution:** Manually delete stuck apps with cascade option in ArgoCD UI

### LoadBalancer Issues

**Problem:** envoy-gateway service stuck in "Pending" state
```bash
# Ensure old kgateway namespace is completely deleted
kubectl get ns kgateway-system

# If it exists, force delete any stuck resources
kubectl patch namespace kgateway-system -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**Problem:** Applications return 502/503 errors
```bash
# Check envoy-gateway pod logs
kubectl logs -l app.kubernetes.io/name=envoy-gateway -n envoy-gateway-system

# Verify gateway is ready
kubectl describe gateway https -n envoy-gateway-system
```

### Emergency Rollback

If you need to rollback immediately:

```bash
# 1. Revert ArgoCD cluster-forge to v2.0.5
# In ArgoCD UI: cluster-forge > Sources > Edit > Change TARGET REVISION to v2.0.5

# 2. Wait for kgateway apps to be restored

# 3. Delete envoy-gateway namespace if needed
kubectl delete namespace envoy-gateway-system
```

## Quick Reference

### Migration Summary
```bash
# Step 1: Migration job
kubectl apply -f cluster-forge/scripts/utils/envoy-gateway-migration.yaml

# Step 2: ArgoCD update
# ArgoCD UI: cluster-forge > Sources > Edit > v2.0.5 → v2.0.6 > Save > Sync

# Step 3: Cleanup
kubectl delete namespace kgateway-system
kubectl delete crd gateways.gateway.kgateway.dev gatewayextensions.gateway.kgateway.dev trafficpolicies.gateway.kgateway.dev --ignore-not-found
```

### Key Commands
```bash
# Check migration status
kubectl get job envoy-gateway-migration -n envoy-gateway-system

# Monitor envoy-gateway 
kubectl get pods -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system

# Verify applications
kubectl get httproutes -A
kubectl get gateways -A
```

### Important URLs
- **ArgoCD:** `https://argocd.<your-domain>`
- **Gitea:** `https://gitea.<your-domain>`

## Additional Notes

- **Migration Job Auto-Cleanup:** The migration job will auto-delete after 10 minutes
- **Idempotent Process:** Safe to re-run migration job if interrupted
- **Zero Data Loss:** No cluster data is modified during this migration
- **Rollback Window:** Can safely rollback within 1 hour of migration

## Support

If you encounter issues not covered in this guide:

1. **Check ArgoCD application logs** for specific error messages
2. **Review envoy-gateway pod logs** for gateway-specific issues  
3. **Verify network connectivity** between components
4. **Consult the troubleshooting section** for common scenarios

---

**Migration Path:** kgateway (v2.0.5) → envoy-gateway (v2.0.6)  
**Estimated Time:** 20-30 minutes  
**Complexity:** Low (2 manual steps)  
**Risk Level:** Low (full rollback available)
