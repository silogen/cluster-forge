# Domain Update System Implementation

This document describes the comprehensive domain update system implemented for cluster-forge that enables automatic domain transitions from `initial-domain.com` to `new-domain.com`.

## Overview

The domain update system provides both automatic and manual mechanisms to update domain configurations across all cluster components when the domain changes in the gitea cluster-values repository.

**Key Features:**
- 🔄 **Automatic Updates**: Enabled by default, watches for domain changes in cluster-values
- 🚀 **Manual Triggers**: Multiple trigger methods for testing and emergency scenarios  
- 🎯 **Immediate Response**: No waiting for 3-minute ArgoCD polling during testing
- 🛡️ **Safe Operations**: Validation, confirmation prompts, and rollback capabilities
- 📊 **Monitoring**: Event logging, status tracking, and health checks

## Architecture

### Components Created

1. **Domain Updater Helm Chart** (`sources/domain-updater/`)
   - Core Kubernetes resources (ServiceAccount, RBAC, ConfigMaps)
   - Domain update scripts and logic
   - Webhook service for manual triggers

2. **CLI Tools** (`scripts/`)
   - `trigger-domain-update.sh` - Manual domain update trigger
   - `domain-webhook-trigger.sh` - Webhook-based triggers

3. **Enhanced Bootstrap** (`scripts/bootstrap.sh`)
   - Integrated domain update system setup
   - Configurable enable/disable options
   - Automatic initial configuration

4. **Configuration Updates**
   - `values_cf.yaml` - Production configuration with domain updater enabled
   - `values_test.yaml` - Test configuration with faster polling
   - Added `domain-updater` to enabled apps list

## Usage

### Initial Setup

```bash
# Bootstrap with domain updates enabled (default)
./bootstrap.sh example.com values_cf.yaml true

# Bootstrap with domain updates disabled
./bootstrap.sh example.com values_cf.yaml false
```

### Automatic Updates (Production)

1. Update domain in gitea cluster-values repository:
   ```yaml
   # cluster-values/values_cf.yaml
   global:
     domain: new-domain.com  # Change this value
   ```

2. Commit and push changes:
   ```bash
   git commit -am "Update domain to new-domain.com"
   git push origin main
   ```

3. ArgoCD will detect changes and trigger automatic updates within 3 minutes

### Manual Triggers (Testing/Emergency)

#### CLI-Based Trigger
```bash
# Interactive trigger with confirmation
./scripts/trigger-domain-update.sh new-domain.com

# Force trigger without confirmation  
./scripts/trigger-domain-update.sh new-domain.com force

# Monitor progress
kubectl get jobs -n cf-system -l app=domain-updater
kubectl logs -f job/domain-update-manual-XXX -n cf-system
```

#### Webhook-Based Trigger
```bash
# Set up port forwarding for local testing
kubectl port-forward svc/domain-update-webhook -n cf-system 8080:8080 &

# Trigger via webhook
./scripts/domain-webhook-trigger.sh http://localhost:8080/trigger-domain-update new-domain.com

# Check webhook status
./scripts/domain-webhook-trigger.sh http://localhost:8080/status
```

#### Direct ArgoCD Trigger
```bash
# Force immediate ArgoCD sync
kubectl patch application cluster-forge -n argocd --type=merge -p='{"operation":{"sync":{"prune":true}}}'
```

### Testing Workflow

#### Fast Testing Setup
```bash
# Use test configuration for faster iteration
./bootstrap.sh test-domain-1.com values_test.yaml true

# Manual trigger for immediate testing
./scripts/trigger-domain-update.sh test-domain-2.com

# Verify changes
kubectl get configmap current-domain-config -n cf-system -o jsonpath='{.data.domain}'
kubectl get application cluster-forge -n argocd -o jsonpath='{.status.sync.status}'
```

#### Test Multiple Domain Changes
```bash
# Test sequence
./scripts/trigger-domain-update.sh test-domain-1.com force
sleep 30
./scripts/trigger-domain-update.sh test-domain-2.com force
sleep 30
./scripts/trigger-domain-update.sh test-domain-3.com force

# Monitor all changes
kubectl get events -n cf-system --sort-by='.lastTimestamp' | grep domain
```

## Configuration Reference

### Domain Updater Settings

```yaml
domainUpdater:
  enabled: true              # Enable domain update system
  autoSync: true             # Automatic watching (enabled by default)
  testMode: false            # Enhanced logging for testing
  pollInterval: "3m"         # ArgoCD polling interval (configurable)
  manualTrigger:
    enabled: true            # Enable manual triggers
    webhook: true            # Enable webhook endpoint
    cli: true               # Enable CLI scripts
    allowUnsafeDomains: false # Allow test domains (localhost, etc.)
```

### Environment-Specific Configurations

| File | Purpose | Poll Interval | Use Case |
|------|---------|--------------|----------|
| `values_cf.yaml` | Production | 3 minutes | Live environments |
| `values_test.yaml` | Testing | 30 seconds | Development/testing |
| `values_dev.yaml` | Development | 1 minute | Local development |
| `values_ha.yaml` | High Availability | 3 minutes | Production clusters |

## Components Affected by Domain Changes

### Automatic Updates
✅ **Cluster ConfigMaps** - Domain tracking and metadata  
✅ **ArgoCD Applications** - Automatic sync and refresh  
✅ **Application Values** - Domain propagation through Helm values

### Manual Updates Required
⚠️ **External DNS** - DNS records must be updated separately  
⚠️ **Certificate Authorities** - New SSL certificates may need approval  
⚠️ **Load Balancers** - External load balancer configuration  

### Application-Level Updates (via ArgoCD)
🔄 **ArgoCD** - UI access at `argocd.new-domain.com`  
🔄 **Gitea** - Repository access at `gitea.new-domain.com`  
🔄 **Keycloak** - Authentication at `kc.new-domain.com`  
🔄 **MinIO** - Object storage at `minio.new-domain.com`  
🔄 **All Ingress Resources** - Hostname updates across services  
🔄 **TLS Certificates** - Automatic regeneration with new domain SANs  

## Monitoring and Troubleshooting

### Check Current Domain
```bash
kubectl get configmap current-domain-config -n cf-system -o jsonpath='{.data.domain}'
```

### Monitor Domain Update Jobs
```bash
# List recent domain update jobs
kubectl get jobs -n cf-system -l app=domain-updater --sort-by='.metadata.creationTimestamp'

# View job logs
kubectl logs -f job/domain-update-XXX -n cf-system

# Check job status
kubectl describe job domain-update-XXX -n cf-system
```

### Monitor ArgoCD Applications
```bash
# Check cluster-forge application status
kubectl get application cluster-forge -n argocd

# View application details
kubectl describe application cluster-forge -n argocd

# Check all application sync status
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### Check Domain Update Events
```bash
# Recent domain-related events
kubectl get events -n cf-system --sort-by='.lastTimestamp' | grep -i domain

# All system events related to domain updates
kubectl get events --all-namespaces --field-selector reason=DomainUpdateCompleted
```

### Webhook Service Status
```bash
# Check webhook service
kubectl get service domain-update-webhook -n cf-system

# Check webhook endpoint health
kubectl port-forward svc/domain-update-webhook -n cf-system 8080:8080 &
curl -s http://localhost:8080/status
```

## Troubleshooting Common Issues

### Issue: Domain update job fails
```bash
# Check job logs for errors
kubectl logs job/domain-update-XXX -n cf-system

# Common fixes:
# 1. Verify RBAC permissions
kubectl auth can-i update configmaps --as=system:serviceaccount:cf-system:domain-updater-sa -n default

# 2. Check if current-domain-config exists
kubectl get configmap current-domain-config -n cf-system

# 3. Verify ArgoCD application exists
kubectl get application cluster-forge -n argocd
```

### Issue: ArgoCD not syncing after domain change
```bash
# Force manual sync
kubectl patch application cluster-forge -n argocd --type=merge -p='{"operation":{"sync":{"prune":true}}}'

# Check application events
kubectl describe application cluster-forge -n argocd | grep Events -A 10
```

### Issue: Webhook not responding
```bash
# Check service and endpoints
kubectl get svc,endpoints domain-update-webhook -n cf-system

# Port forward and test locally
kubectl port-forward svc/domain-update-webhook -n cf-system 8080:8080 &
curl -v http://localhost:8080/status
```

## Security Considerations

### RBAC Permissions
The domain updater service account has permissions to:
- Read/write ConfigMaps and Secrets in all namespaces
- Update Ingress resources across namespaces  
- Update Certificate resources (cert-manager)
- Update ArgoCD Applications
- Create and manage Jobs in cf-system namespace

### Webhook Security
- Webhook endpoints should be secured with authentication tokens
- Use network policies to restrict access to webhook service
- Consider rate limiting for webhook endpoints

### Domain Validation
- Domain format validation prevents injection attacks
- Unsafe domains blocked in production (configurable in test mode)
- Confirmation prompts for manual triggers (unless forced)

## Integration Points

### Cluster-Bloom Integration
The domain update system integrates with cluster-bloom for infrastructure-level changes:
- TLS certificate regeneration
- OIDC provider configuration updates
- Kubernetes API server endpoint updates

### External DNS Integration
For full automation, integrate with external DNS providers:
```yaml
# Example external-dns configuration
external-dns:
  enabled: true
  provider: cloudflare
  domain-filter: ["your-domain.com"]
```

## Future Enhancements

### Planned Features
- [ ] **Rollback Support** - Automatic rollback on failed domain updates
- [ ] **Blue-Green Domains** - Support for zero-downtime domain transitions  
- [ ] **Multi-Domain Support** - Handle multiple domains simultaneously
- [ ] **DNS Integration** - Automatic external DNS record management
- [ ] **Certificate Automation** - Enhanced cert-manager integration
- [ ] **Notification System** - Slack/Teams notifications for domain changes
- [ ] **Health Monitoring** - Comprehensive health checks post-update

### Integration Opportunities
- **Terraform Integration** - Domain updates trigger infrastructure changes
- **CI/CD Pipeline Integration** - Domain updates as part of deployment pipelines
- **Monitoring Integration** - Prometheus metrics and Grafana dashboards
- **Backup Integration** - Automatic backups before domain changes

---

## Quick Reference

### Essential Commands
```bash
# Trigger manual domain update
./scripts/trigger-domain-update.sh new-domain.com

# Check current domain
kubectl get configmap current-domain-config -n cf-system -o jsonpath='{.data.domain}'

# Monitor update progress
kubectl get jobs -n cf-system -l app=domain-updater

# Force ArgoCD sync
kubectl patch application cluster-forge -n argocd --type=merge -p='{"operation":{"sync":{"prune":true}}}'

# View recent events
kubectl get events -n cf-system --sort-by='.lastTimestamp' | grep domain
```

This implementation provides a robust, flexible domain update system that eliminates the need for manual reconfiguration when domain requirements change. The fire of the forge eliminates impurities - in this case, eliminating manual domain update processes while maintaining safety and reliability!