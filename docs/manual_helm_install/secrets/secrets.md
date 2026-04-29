# AIWB Secrets Reference

## Table of Contents

- [Secret Sources](#secret-sources)
  - [secrets-aiwb.yaml](#secrets-aiwbyaml)
  - [Inline CNPG credential secrets](#inline-cnpg-credential-secrets)
  - [secrets-aiwb-minio.yaml](#secrets-aiwb-minioyaml)
  - [secrets-override-hardcoded.yaml](#secrets-override-hardcodedyaml)
  - [secrets-aiwb-standalone.yaml](#secrets-aiwb-standaloneyaml)
- [Complete Secret Reference](#complete-secret-reference)
  - [Namespace: aiwb](#namespace-aiwb)
  - [Namespace: keycloak](#namespace-keycloak)
  - [Namespace: workbench](#namespace-workbench)
  - [Namespace: minio-tenant-default](#namespace-minio-tenant-default)
  - [Namespace: metallb-system](#namespace-metallb-system)
- [Hardcoded Values Reference](#hardcoded-values-reference)

---

Having an external secrets management system is a best practice, but for out-of-box testing the minimum requirement is that secrets from the following sources are available in the cluster:

## Secret Sources

### secrets-aiwb.yaml
This manifest contains the application-level secrets for the AI Workbench deployment that are always required regardless of pluggable mode. All values use `placeholder` by default and should be replaced with secure credentials for production.

### Inline CNPG credential secrets
CNPG-specific Postgres credentials (superuser + application user) for the in-cluster CloudNativePG Clusters serving AIWB and Keycloak. Created inline by `install_base.sh` when `PLUGGABLE_DB=false`, populated from `AIWB_DB_USER` / `AIWB_DB_PASSWORD`, `KEYCLOAK_DB_USER` / `KEYCLOAK_DB_PASSWORD`, and the `*_CNPG_SUPERUSER_*` env vars (which default to `placeholder`). In `PLUGGABLE_DB=true` mode the script instead creates env-based user secrets (`AIWB_DB_SECRET_NAME`, `KEYCLOAK_DB_SECRET_NAME`) pointing at the external Postgres host.

### secrets-aiwb-minio.yaml
MinIO-related secrets: `minio-credentials` in the `aiwb` and `workbench` namespaces, plus `default-user` for the in-cluster MinIO Tenant. `install_base.sh` only applies this file when `PLUGGABLE_S3=false`. In `PLUGGABLE_S3=true` mode the script instead creates `minio-credentials` in `aiwb` and `workbench` from `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY`, and `default-user` is not needed (no in-cluster Tenant is installed).

### secrets-override-hardcoded.yaml
This manifest contains secrets with values that CANNOT be `placeholder` due to hardcoded expectations in Helm charts or other components. These override corresponding secrets from `secrets-aiwb.yaml`.

### secrets-aiwb-standalone.yaml
This manifest contains additional secrets specific to standalone deployment mode. Required for MetalLB memberlist encryption and workspace MinIO access.

---

## Complete Secret Reference

All required secrets for AIWB deployment, organized by namespace:

### Namespace: `aiwb`

#### 1. `aiwb-cnpg-superuser`
PostgreSQL superuser credentials for AIWB database cluster.

**Keys:**
- `username` — PostgreSQL admin username (from `${AIWB_CNPG_SUPERUSER_USER}`, default: `placeholder`)
- `password` — PostgreSQL admin password (from `${AIWB_CNPG_SUPERUSER_PASSWORD}`, default: `placeholder`)

**Source:** Created inline by `install_base.sh` (applied only when `PLUGGABLE_DB=false`)

---

#### 2. `aiwb-cnpg-user`
PostgreSQL application user credentials for AIWB database.

**Keys:**
- `username` — PostgreSQL username (from `${AIWB_DB_USER}`, default: `placeholder`)
- `password` — PostgreSQL password (from `${AIWB_DB_PASSWORD}`, default: `placeholder`)

**Source:** Created inline by `install_base.sh` (applied only when `PLUGGABLE_DB=false`)  
**Note:** In `PLUGGABLE_DB=true` mode, replaced by env-based `${AIWB_DB_SECRET_NAME}` Secret pointing at the external Postgres host.

---

#### 3. `aiwb-nextauth-secret`
NextAuth.js session encryption secret for AIWB UI.

**Keys:**
- `NEXTAUTH_SECRET` — Secret key for session encryption (default: `placeholder`)

**Source:** secrets-aiwb.yaml  
**Note:** Should be a random 32+ character string in production

---

#### 4. `aiwb-ui-keycloak-secret`
Keycloak OIDC client secret for AIWB UI authentication.

**Keys:**
- `value` — Keycloak client secret (default: `placeholder`)

**Source:** secrets-aiwb.yaml  
**Note:** Must match the client secret configured in Keycloak `airm` realm

---

#### 5. `cluster-auth-admin-token`
Admin token for cluster-auth service API calls.

**Keys:**
- `value` — Admin API token (default: `placeholder`)

**Source:** secrets-aiwb.yaml  
**Note:** Only required in non-standalone mode

---

#### 6. `minio-credentials`
S3/MinIO access credentials for AIWB application.

**Keys:**
- `minio-access-key` — S3 access key ID (default: `placeholder`)
- `minio-secret-key` — S3 secret access key (default: `placeholder`)

**Source:** secrets-aiwb-minio.yaml (applied only when `PLUGGABLE_S3=false`)  
**Note:** Must match MinIO tenant root credentials. In `PLUGGABLE_S3=true` mode, `install_base.sh` creates this Secret from `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` env vars instead.

---

### Namespace: `keycloak`

#### 7. `keycloak-cnpg-superuser`
PostgreSQL superuser credentials for Keycloak database cluster.

**Keys:**
- `username` — PostgreSQL admin username (from `${KEYCLOAK_CNPG_SUPERUSER_USER}`, default: `placeholder`)
- `password` — PostgreSQL admin password (from `${KEYCLOAK_CNPG_SUPERUSER_PASSWORD}`, default: `placeholder`)

**Source:** Created inline by `install_base.sh` (applied only when `PLUGGABLE_DB=false`)

---

#### 8. `keycloak-cnpg-user`
PostgreSQL application user credentials for Keycloak database.

**Keys:**
- `username` — PostgreSQL username (from `${KEYCLOAK_DB_USER}`, default: `placeholder`)
- `password` — PostgreSQL password (from `${KEYCLOAK_DB_PASSWORD}`, default: `placeholder`)

**Source:** Created inline by `install_base.sh` (applied only when `PLUGGABLE_DB=false`)  
**Note:** In `PLUGGABLE_DB=true` mode, replaced by env-based `${KEYCLOAK_DB_SECRET_NAME}` Secret pointing at the external Postgres host.

---

#### 9. `keycloak-credentials`
Keycloak admin console credentials.

**Keys:**
- `KEYCLOAK_INITIAL_ADMIN_PASSWORD` — Admin user initial password (default: `placeholder`)

**Source:** secrets-aiwb.yaml  
**Note:** Used to create initial admin user `silogen-admin`

---

#### 10. `airm-realm-credentials`
Keycloak `airm` realm configuration secrets.

**Keys:**
- `ADMIN_CLIENT_ID` — Admin client ID (default: `placeholder`)
- `ADMIN_CLIENT_SECRET` — Admin client secret (default: `placeholder`)
- `ARGOCD_CLIENT_SECRET` — ArgoCD OIDC client secret (default: `placeholder`)
- `CI_CLIENT_SECRET` — CI/CD OIDC client secret (default: `placeholder`)
- `FRONTEND_CLIENT_SECRET` — Frontend client secret (default: `placeholder`)
- `GITEA_CLIENT_SECRET` — Gitea OIDC client secret (default: `placeholder`)
- `K8S_CLIENT_SECRET` — Kubernetes API OIDC client secret (default: `placeholder`)
- `KEYCLOAK_INITIAL_DEVUSER_PASSWORD` — Initial dev user password (default: `placeholder`)
- `MINIO_CLIENT_SECRET` — MinIO OIDC client secret (default: `placeholder`)

**Source:** secrets-aiwb.yaml  
**Note:** Used by Keycloak realm import init container

---

### Namespace: `workbench`

#### 11. `minio-credentials`
S3/MinIO access credentials for workspace pods.

**Keys:**
- `minio-access-key` — S3 access key ID (default: `placeholder`)
- `minio-secret-key` — S3 secret access key (default: `placeholder`)

**Source:** secrets-aiwb-minio.yaml, secrets-aiwb-standalone.yaml (applied only when `PLUGGABLE_S3=false`)  
**Note:** Workspace pods use this to access object storage. In `PLUGGABLE_S3=true` mode, `install_base.sh` creates this Secret from `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` env vars instead.

---

### Namespace: `minio-tenant-default`

#### 12. `default-user`
MinIO tenant user credentials.

**Keys:**
- `API_ACCESS_KEY` — MinIO API access key (**hardcoded:** `api-default-user`)
- `API_SECRET_KEY` — MinIO API secret key (default: `placeholder`)
- `CONSOLE_ACCESS_KEY` — MinIO console access key (default: `placeholder`)
- `CONSOLE_SECRET_KEY` — MinIO console secret key (default: `placeholder`)

**Source:** secrets-aiwb-minio.yaml, secrets-override-hardcoded.yaml (applied only when `PLUGGABLE_S3=false`)  
**Note:** API_ACCESS_KEY is hardcoded in OpenBao secret definitions. Not needed in `PLUGGABLE_S3=true` mode (no in-cluster MinIO Tenant is installed).

---

### Namespace: `metallb-system`

#### 13. `memberlist`
MetalLB memberlist encryption key.

**Keys:**
- `secretkey` — Memberlist secret key (default: `placeholder`)

**Source:** secrets-aiwb-standalone.yaml  
**Note:** Used for encrypted communication between MetalLB speaker nodes

---

### Hardcoded Values Reference

The following value is **hardcoded** in component configuration and cannot be changed without modifying it:

| Secret | Namespace | Key | Hardcoded Value | Reason |
|--------|-----------|-----|-----------------|--------|
| `default-user` | minio-tenant-default | `API_ACCESS_KEY` | `api-default-user` | OpenBao secret definitions |

This value is pre-configured in `secrets-override-hardcoded.yaml`.
