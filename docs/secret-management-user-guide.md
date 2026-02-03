# Secret Management User Guide

This guide provides practical instructions for end-users to manage secrets in the cluster-forge OpenBao system.

## Overview

The cluster-forge secret management system uses a **declarative, GitOps-based approach** where secrets are defined in configuration files and automatically created by a CronJob that runs every 5 minutes.

**How it works:**
- **For existing components**: All application secrets are already defined and automatically managed
- **For new components**: When you add a new application that needs secrets, you define them in the configuration file, commit the changes, and they're automatically created in OpenBao. Your new component can then fetch these secrets via External Secrets Operator using ExternalSecret resources that reference the OpenBao paths.

**Example workflow for new components:**
1. Add your application deployment files
2. Define required secrets in `openbao-secret-definitions.yaml` 
3. Create ExternalSecret resources to fetch the secrets from OpenBao
4. Your application pods automatically receive the secrets as Kubernetes Secret mounts

## Quick Start: Adding a New Secret

### 1. Edit the Secret Definition File

Navigate to and edit:
```
sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml
```

### 2. Add Your Secret Definition

Add a new line following this format:
```
SECRET_PATH|TYPE|VALUE|BYTES
```

**Examples:**
```bash
# Random 32-byte password for your application
secrets/my-app-database-password|random||32

# Static API key
secrets/my-app-api-key|static|your-fixed-api-key-here|0

# Domain-based URL (uses templating)
secrets/my-app-callback-url|static|https://my-app.{{ .Values.domain }}/callback|0
```

### 3. Commit and Push Changes

```bash
git add sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml
git commit -m "feat: add secrets for my-app"
git push origin main
```

### 4. Wait for Automatic Creation

The GitOps pipeline will automatically create your secrets. **Total time: ~20-25 minutes**

**Pipeline stages:**
- **GitHub → Gitea sync**: ~15 minutes (Gitea syncs every 15 minutes)
- **ArgoCD deployment**: ~3 minutes (ArgoCD detects and deploys changes)
- **Secret creation**: ~0-5 minutes (CronJob runs every 5 minutes)

**Monitor progress:**
```bash
# Check ArgoCD sync status
kubectl get application openbao-config -n argocd

# Check recent CronJob executions
kubectl get jobs -n cf-openbao -l job-name=openbao-secret-manager --sort-by=.metadata.creationTimestamp
```

**✅ Your secrets are ready when:** The CronJob shows a successful completion and you can verify the secret exists in OpenBao.

## Secret Definition Format Reference

### Format Specification

```
SECRET_PATH|TYPE|VALUE|BYTES
```

### Field Descriptions

| Field | Description | Examples |
|-------|-------------|----------|
| **SECRET_PATH** | Path where secret will be stored in OpenBao | `secrets/my-app-password` |
| **TYPE** | Secret type: `static` or `random` | `random`, `static` |
| **VALUE** | Used only for static secrets (supports templating) | `my-api-key`, `https://api.{{ .Values.domain }}/v1` |
| **BYTES** | Used only for random secrets (length in bytes) | `16`, `32`, `64` |

### Secret Types

**Random Secrets:**
```bash
# Format: secrets/path|random||BYTES
secrets/my-app-password|random||16        # 16-byte password
secrets/api-key|random||32               # 32-byte API key
```

**Static Secrets:**
```bash
# Format: secrets/path|static|VALUE|0
secrets/my-api-url|static|https://api.example.com|0           # Fixed value
secrets/my-callback|static|https://app.{{ .Values.domain }}|0  # Domain templating
```

## Working with Secrets

### Viewing Secret Values

```bash
# Check if secret exists in OpenBao
kubectl exec -n cf-openbao openbao-0 -- bao kv get secrets/my-app-password

# View secret value (requires access)
kubectl exec -n cf-openbao openbao-0 -- bao kv get -field=value secrets/my-app-password
```

**Note**: Secrets are never updated automatically once created to prevent breaking applications.

## Using Secrets in Applications

### 1. Create an ExternalSecret Resource

Create a file like `my-app-external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  refreshInterval: 60s
  secretStoreRef:
    name: openbao-secret-store
    kind: ClusterSecretStore
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: secrets/my-app-password
        property: value
    - secretKey: api-key
      remoteRef:
        key: secrets/my-app-api-key
        property: value
```

### 2. Use the Secret in Your Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: my-namespace
spec:
  containers:
  - name: app
    image: my-app:latest
    env:
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: my-app-secret
          key: password
    - name: API_KEY
      valueFrom:
        secretKeyRef:
          name: my-app-secret
          key: api-key
```

## Current Secret Inventory

For a complete and up-to-date list of all secrets in the system, refer to the **source of truth**:

```
sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml
```

This file contains all currently defined secrets organized by category:
- **Cluster-Wide**: Domain configuration
- **AIRM Application**: Database, RabbitMQ, and UI authentication secrets  
- **Keycloak**: Admin passwords and database credentials
- **MinIO**: Storage access keys and console credentials
- **Infrastructure**: Client secrets for Kubernetes, Gitea, and ArgoCD
- **AIWB Application**: Database and authentication secrets

**To view current secrets:**
```bash
# View the complete secret definitions file
cat sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml

# Or check specific secrets in OpenBao
kubectl exec -n cf-openbao openbao-0 -- bao kv list secrets/
```

## Troubleshooting

### Secret Not Created After 25 Minutes

1. **Check ArgoCD sync status:**
   ```bash
   kubectl get application openbao-config -n argocd
   ```

2. **Check CronJob execution:**
   ```bash
   kubectl get cronjob openbao-secret-manager -n cf-openbao
   kubectl get jobs -n cf-openbao -l job-name=openbao-secret-manager
   ```

3. **Check CronJob logs:**
   ```bash
   # Get the most recent job
   JOB=$(kubectl get jobs -n cf-openbao -l job-name=openbao-secret-manager --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
   kubectl logs job/$JOB -n cf-openbao
   ```

### Secret Definition Format Errors

**Error**: CronJob fails with parsing errors

**Solution**: Check your secret definition format:
- Ensure exactly 4 fields separated by `|`
- No extra spaces around the `|` separators
- For random secrets: VALUE field should be empty
- For static secrets: BYTES field should be `0`

**Example of incorrect format:**
```bash
# Wrong - extra spaces
secrets/my-secret | random | | 32

# Wrong - missing field
secrets/my-secret|random|32

# Correct
secrets/my-secret|random||32
```

### Common Issues

**ExternalSecret not syncing:**
```bash
kubectl get externalsecret my-app-secrets -n my-namespace
kubectl describe externalsecret my-app-secrets -n my-namespace
```

**Secret not found in OpenBao:**
```bash
kubectl exec -n cf-openbao openbao-0 -- bao kv get secrets/my-app-password
```

## Best Practices

**Naming:** Use descriptive, hierarchical names like `secrets/my-app-database-password`

**Security:** Never commit actual secret values to git. Use random secrets for passwords/tokens.

**Organization:** Group related secrets with consistent prefixes (e.g., `secrets/airm-*`)

**Change Management:** Test in development first, existing secrets are never updated automatically.

## Getting Help

**For issues:** Check troubleshooting section, ArgoCD/CronJob logs, or see [secrets management architecture documentation](secrets_management_architecture.md)

**For architectural details:** See [secrets management architecture documentation](secrets_management_architecture.md) for comprehensive system overview