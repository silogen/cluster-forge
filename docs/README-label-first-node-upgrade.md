# First Node Labeling for kgateway Upgrade

## What This Does

This tool identifies and labels the first node with `cluster-bloom/first-node=true` in existing clusters. This label is required for kgateway pods to schedule on the correct node with the proper external IP configuration.

## When You Need This

**For existing clusters having cluster-forge applied only** - this job adds the required `cluster-bloom/first-node=true` label to your first node so that kgateway pods can target it correctly.

⚠️ **Not needed for fresh cluster-bloom deployments** - they get the label automatically.

## Quick Usage

```bash
# 1. Ensure MetalLB is deployed
kubectl get ipaddresspool cluster-bloom-ip-pool -n metallb-system

# 2. Apply the upgrade job
kubectl apply -f label-first-node-upgrade.yaml

# 3. Monitor progress
kubectl logs -f job/label-first-node-upgrade

# 4. Proceed with cluster-forge upgrade
```

## How It Works

1. **Finds your MetalLB IP** from the existing IPAddressPool
2. **Discovers the matching node** using IP annotations
3. **Applies the label** `cluster-bloom/first-node=true`
4. **Auto-deletes** after 5 minutes

## Expected Output

```
🔧 First Node Labeling Job for kgateway Upgrade
✅ MetalLB IPAddressPool found
✅ Found MetalLB IP: 192.168.1.100
🎯 Target node identified: worker-node-1
✅ Label applied successfully
✅ SUCCESS! Upgrade preparation complete!
```

## Prerequisites

- kubectl access with admin permissions
- MetalLB already deployed by cluster-forge
- Ready to upgrade cluster-forge

## Troubleshooting

| Error | Solution |
|-------|----------|
| `MetalLB IPAddressPool not found` | Deploy MetalLB via cluster-forge first |
| `No node found with IP` | Check MetalLB IP matches a node IP |
| `Failed to apply label` | Verify cluster admin permissions |

## After Running This

1. ✅ Proceed with cluster-forge upgrade
2. ✅ kgateway pods will target the labeled node
3. ✅ Production traffic routing will work reliably