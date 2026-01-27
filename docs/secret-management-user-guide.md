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
sources/openbao-config/templates/openbao-secret-definitions.yaml
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

### 3. Commit and Deploy

```bash
git add sources/openbao-config/templates/openbao-secret-definitions.yaml
git commit -m "feat: add secrets for my-app"
git push origin main
```

### 4. Wait for Automatic Creation

After Gitea synchronizes cluster-forge from GitHub, the GitOps process begins:

- **Gitea sync from GitHub**: ~1-2 minutes (Gitea pulls changes from upstream)
- **ArgoCD detects changes**: ~1-3 minutes (ArgoCD polls Gitea for changes)
- **ArgoCD deploys updates**: ~1-2 minutes (Helm templates processed and applied)
- **CronJob execution**: ~0-5 minutes (Next scheduled run creates the secrets)
- **Total time**: ~3-12 minutes (depending on timing of each stage)

**Monitoring the process:**
```bash
# Check if Gitea has the latest commit
# (Compare with your GitHub commit hash)

# Check ArgoCD sync status
kubectl get application openbao-config -n argocd

# Check recent CronJob executions
kubectl get jobs -n cf-openbao -l job-name=openbao-secret-manager --sort-by=.metadata.creationTimestamp
```

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

#### 1. Random Secrets
Automatically generated using OpenBao's cryptographic random generator.

**Format:**
```
secrets/path|random||BYTES
```

**Examples:**
```bash
# 16-byte (128-bit) password
secrets/database-password|random||16

# 32-byte (256-bit) API key
secrets/api-secret-key|random||32

# 64-byte (512-bit) signing key
secrets/jwt-signing-key|random||64
```

**Common byte lengths:**
- `16 bytes` = 128 bits (good for passwords)
- `32 bytes` = 256 bits (good for API keys, tokens)
- `64 bytes` = 512 bits (good for signing keys)

#### 2. Static Secrets
Fixed values that you specify, with optional domain templating.

**Format:**
```
secrets/path|static|VALUE|0
```

**Examples:**
```bash
# Fixed API endpoint
secrets/external-api-url|static|https://api.external-service.com/v1|0

# Domain-based URL (templated)
secrets/callback-url|static|https://my-app.{{ .Values.domain }}/auth/callback|0

# Fixed username
secrets/service-account|static|my-service-user|0
```

**Domain Templating:**
- Use `{{ .Values.domain }}` in static values
- Will be replaced with the actual cluster domain during deployment
- Example: `{{ .Values.domain }}` → `app.silogen.ai`

## Working with Secrets

### Checking if a Secret Exists

```bash
# Check if secret exists in OpenBao
kubectl exec -n cf-openbao openbao-0 -- bao kv get secrets/my-app-password

# Check External Secret status
kubectl get externalsecret -n my-namespace my-app-secrets -o yaml
```

### Viewing Secret Values (for debugging)

```bash
# View secret from OpenBao directly (requires root token)
kubectl exec -n cf-openbao openbao-0 -- bao kv get -field=value secrets/my-app-password

# View secret in Kubernetes (after External Secrets sync)
kubectl get secret -n my-namespace my-app-secret -o jsonpath='{.data.password}' | base64 -d
```

### Updating Static Secrets

1. Edit the secret definition file
2. Change the VALUE field for your static secret
3. Commit and push changes
4. **Important**: Delete the existing secret from OpenBao to force recreation:
   ```bash
   kubectl exec -n cf-openbao openbao-0 -- bao kv delete secrets/my-app-api-key
   ```
5. Wait for next CronJob execution (~5 minutes)

**Note**: Random secrets are never updated automatically to prevent breaking applications.

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

### Cluster-Wide Secrets
- `secrets/cluster-domain` - Current cluster domain

### AIRM Application Secrets
- `secrets/airm-cnpg-user-username` - Database username
- `secrets/airm-cnpg-user-password` - Database password  
- `secrets/airm-cnpg-superuser-username` - Database superuser
- `secrets/airm-cnpg-superuser-password` - Database superuser password
- `secrets/airm-rabbitmq-user-username` - RabbitMQ username
- `secrets/airm-rabbitmq-user-password` - RabbitMQ password
- `secrets/airm-ui-keycloak-secret` - Keycloak client secret
- `secrets/airm-ui-auth-nextauth-secret` - NextAuth secret
- `secrets/airm-ci-client-secret` - CI client secret
- `secrets/airm-keycloak-admin-client-id` - Keycloak admin client ID
- `secrets/airm-keycloak-admin-client-secret` - Keycloak admin secret

### Keycloak Secrets
- `secrets/keycloak-initial-admin-password` - Initial admin password
- `secrets/keycloak-initial-devuser-password` - Dev user password
- `secrets/keycloak-cnpg-user-username` - Database username
- `secrets/keycloak-cnpg-user-password` - Database password
- `secrets/keycloak-cnpg-superuser-username` - Database superuser
- `secrets/keycloak-cnpg-superuser-password` - Database superuser password

### MinIO Secrets
- `secrets/minio-api-access-key` - API access key
- `secrets/minio-api-secret-key` - API secret key
- `secrets/minio-console-access-key` - Console access key
- `secrets/minio-console-secret-key` - Console secret key
- `secrets/minio-root-password` - Root password
- `secrets/minio-client-secret` - Client secret
- `secrets/minio-openid-url` - OpenID Connect URL

### Infrastructure Secrets
- `secrets/k8s-client-secret` - Kubernetes client secret
- `secrets/gitea-client-secret` - Gitea client secret
- `secrets/argocd-client-secret` - ArgoCD client secret
- `secrets/cluster-auth-admin-token` - Cluster auth token

## Troubleshooting

### Secret Not Created After 8 Minutes

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

### ExternalSecret Not Syncing

1. **Check ClusterSecretStore status:**
   ```bash
   kubectl get clustersecretstore openbao-secret-store
   ```

2. **Check ExternalSecret status:**
   ```bash
   kubectl describe externalsecret my-app-secrets -n my-namespace
   ```

3. **Verify secret exists in OpenBao:**
   ```bash
   kubectl exec -n cf-openbao openbao-0 -- bao kv get secrets/my-app-password
   ```

### OpenBao Access Issues

**Error**: "Permission denied" or "Authentication failed"

**Solution**: Check OpenBao readonly user credentials:
```bash
kubectl get secret openbao-user -n cf-openbao -o yaml
```

### Domain Templating Not Working

**Issue**: Static secrets with `{{ .Values.domain }}` not getting replaced

**Cause**: Domain templating only works during Helm deployment, not in CronJob

**Solution**: Ensure your static secret uses templating correctly:
```bash
# Correct - will be templated during Helm deployment
secrets/my-callback|static|https://app.{{ .Values.domain }}/callback|0
```

## Best Practices

### 1. Secret Naming Conventions
```bash
# Good - descriptive and hierarchical
secrets/my-app-database-password
secrets/my-app-api-key
secrets/external-service-webhook-secret

# Avoid - too generic or unclear
secrets/password
secrets/key1
secrets/secret
```

### 2. Secret Organization
- Group related secrets with consistent prefixes
- Use descriptive names that indicate the purpose
- Consider the application/service that will use the secret

### 3. Security Considerations
- **Never commit actual secret values** to version control
- Use random secrets for passwords and tokens when possible
- Use appropriate byte lengths for random secrets (16-32 bytes typically sufficient)
- Regularly review and audit secret definitions

### 4. Change Management
- Test secret changes in development environment first
- Plan secret updates during maintenance windows when possible
- Document secret dependencies when adding new applications

## Migration Guide

### From Manual Secret Creation

If you previously created secrets manually in OpenBao:

1. **Document existing secrets:**
   ```bash
   kubectl exec -n cf-openbao openbao-0 -- bao kv list secrets/
   ```

2. **Add them to the configuration file** in the appropriate format

3. **Test in development** to ensure the CronJob recreates them correctly

4. **The CronJob will skip existing secrets**, so manual ones will remain until deleted

### From Old generate-secrets.sh

If upgrading from the old hardcoded script approach:

1. **Review current secret list** in the updated documentation
2. **All existing secrets are now managed declaratively** 
3. **No action required** - the system is backward compatible
4. **New secrets should be added via the configuration file**

## Support and Maintenance

### Regular Tasks

- **Monthly**: Review secret inventory for unused secrets
- **Quarterly**: Audit secret access patterns via External Secrets logs
- **As needed**: Update domain-based static secrets when domains change

### Getting Help

For issues with secret management:
1. Check this user guide first
2. Review the troubleshooting section
3. Check ArgoCD and CronJob logs
4. Consult the [secrets management architecture documentation](secrets-management-architecture.md)