# Domain Updater - Implementation

## Option 1: Ansible Playbook (Recommended)

**Usage:**
```bash
ansible-playbook scripts/trigger-domain-update.yml \
  -e NEW_DOMAIN=newdomain.com \
  -e CERT_PATH=/path/to/cert.pem \
  -e KEY_PATH=/path/to/key.pem \
  -e OLD_DOMAIN=olddomain.com
```

**What it does:**
1. ✅ Validates domain format and certificate files
2. ✅ Detects cluster-bloom DNS configuration (DNSMASQ/FIX_DNS)
3. ✅ Updates cluster-values repository with new domain
4. ✅ Updates system DNS (DNSMASQ) configuration if cluster-bloom was used
5. ✅ Applies new TLS certificates to cluster
6. ✅ Updates domain ConfigMap (triggers ArgoCD detection)
7. ✅ Forces one-time ArgoCD sync for critical apps
8. ✅ Verifies domain accessibility
9. ✅ Automatic rollback on DNS configuration failures

## Option 2: Bash Script (Alternative)

**Usage:**
```bash
./scripts/trigger-domain-update.sh newdomain.com /path/to/cert.pem /path/to/key.pem [old-domain]
```

**Features:**
- 🎯 Interactive confirmation prompts
- 🛡️ Built-in validation and error handling
- 📊 Colored output with progress indicators
- ⚡ Automatic old domain detection from cluster configuration
- 🔍 Automatic cluster-bloom DNS detection
- ⚙️ System DNS (DNSMASQ) configuration updates
- 🔄 DNS rollback on configuration failures

## Features

1. **Automatic Domain Detection**
   - Automatically extracts old domain from cluster configuration
   - Falls back to manual specification if auto-detection fails
   - Extracts domain from gitea-config-script ConfigMap in cf-gitea namespace

2. **Global Domain Templating**
   - All applications still use `{{ .Values.global.domain }}`
   - Helm parameter injection continues to work
   - ArgoCD application definitions unchanged

2. **Simplified Parameters**
   - Uses OLD_DOMAIN parameter instead of full repository URL
   - Repository URL constructed automatically from old domain
   - More user-friendly interface

3. **Manual Script Execution**
   - Clean, single-purpose scripts
   - Direct cluster-values repo updates
   - One-time ArgoCD sync triggers

4. **Certificate Management**
   - TLS secret creation/updates in kgateway-system namespace
   - External Secrets Operator propagates to other namespaces
   - cert-manager integration (if used)

5. **Cluster-Bloom Integration**
   - Automatic detection of DNSMASQ configuration
   - System DNS updates for local domain resolution
   - FIX_DNS detection and validation
   - Complete rollback on DNS failures

## Usage Examples

### Example 1: Basic Domain Change

```bash
# Using Ansible (recommended)
ansible-playbook scripts/trigger-domain-update.yml \
  -e NEW_DOMAIN=prod.example.com \
  -e CERT_PATH=./certs/prod-cert.pem \
  -e KEY_PATH=./certs/prod-key.pem

# Using Bash script
./scripts/trigger-domain-update.sh prod.example.com ./certs/prod-cert.pem ./certs/prod-key.pem
```

### Example 2: With Explicit Old Domain

```bash
# When old domain cannot be auto-detected or you want to be explicit
ansible-playbook scripts/trigger-domain-update.yml \
  -e NEW_DOMAIN=staging.company.org \
  -e CERT_PATH=/etc/ssl/staging.crt \
  -e KEY_PATH=/etc/ssl/staging.key \
  -e OLD_DOMAIN=oldstaging.company.org
```

### Example 3: Dry Run (Validation Only)

```bash
# Ansible check mode
ansible-playbook scripts/trigger-domain-update.yml --check \
  -e NEW_DOMAIN=test.domain.com \
  -e CERT_PATH=./test-cert.pem \
  -e KEY_PATH=./test-key.pem

# Bash script will prompt for confirmation
./scripts/trigger-domain-update.sh test.domain.com ./test-cert.pem ./test-key.pem
# (answer 'n' to cancel after validation)
```

## Verification

After running the domain change script, verify the update:

```bash
# Check current domain
kubectl get configmap current-domain-config -n kgateway-system -o jsonpath='{.data.domain}'

# Check ArgoCD accessibility
curl -k https://argocd.NEWDOMAIN.com/api/version

# Check application sync status
kubectl get applications -n argocd

# Monitor ArgoCD sync progress
kubectl get events -n kgateway-system --sort-by='.lastTimestamp' | grep domain
```

## Troubleshooting

### Common Issues

1. **Certificate File Not Found**
   ```bash
   # Ensure certificate paths are absolute
   ls -la /path/to/cert.pem /path/to/key.pem
   ```

2. **Kubectl Connection Issues**
   ```bash
    # Verify cluster connectivity
    kubectl get namespaces
    kubectl get namespace kgateway-system
   ```

3. **Git Repository Access**
   ```bash
   # Test repository access
   git clone https://gitea.DOMAIN.com/infrastructure/cluster-values.git /tmp/test-clone
   ```

4. **ArgoCD Sync Failures**
   ```bash
   # Force manual sync if needed
   kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
   ```

5. **DNS Configuration Issues**
   ```bash
   # Check if cluster-bloom DNS is configured
   sudo ls -la /etc/dnsmasq.d/keycloak.conf
   
   # Check current DNSMASQ domain
   sudo grep "address=/" /etc/dnsmasq.d/keycloak.conf
   
   # Test DNS resolution
   nslookup your-domain.com 127.0.0.1
   nslookup google.com 127.0.0.1
   
   # Check DNSMASQ service status
   sudo systemctl status dnsmasq
   
   # View DNSMASQ configuration backups
   sudo ls -la /etc/dnsmasq.d/keycloak.conf.backup-*
   ```

6. **DNS Resolution Problems**
   ```bash
   # Manual DNSMASQ restart
   sudo systemctl restart dnsmasq
   
   # Check resolv.conf
   cat /etc/resolv.conf
   
   # Test if systemd-resolved was properly disabled
   systemctl is-active systemd-resolved
   
   # Restore DNSMASQ from backup if needed
   sudo cp /etc/dnsmasq.d/keycloak.conf.backup-TIMESTAMP /etc/dnsmasq.d/keycloak.conf
   sudo systemctl restart dnsmasq
   ```

### Recovery

If domain change fails midway:

```bash
# Check what was updated
kubectl get configmap current-domain-config -n kgateway-system -o yaml
kubectl get secrets -n kgateway-system | grep tls

# Check DNS configuration status
sudo cat /etc/dnsmasq.d/keycloak.conf
sudo ls -la /etc/dnsmasq.d/keycloak.conf.backup-*

# Manual Kubernetes rollback if needed
kubectl patch configmap current-domain-config -n kgateway-system -p '{"data":{"domain":"old-domain.com"}}'

# Manual DNS rollback if needed
sudo cp /etc/dnsmasq.d/keycloak.conf.backup-LATEST /etc/dnsmasq.d/keycloak.conf
sudo systemctl restart dnsmasq

# Trigger ArgoCD sync
kubectl patch application argocd -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

**DNS Recovery Notes:**
- DNS configuration is automatically rolled back on script failure
- Backups are created with timestamps: `/etc/dnsmasq.d/keycloak.conf.backup-TIMESTAMP`
- DNSMASQ service is automatically restored if configuration test fails
- Original resolv.conf backups from cluster-bloom are preserved