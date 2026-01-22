# Secrets Management Architecture

## Overview

This document describes the comprehensive secrets management architecture used in cluster-forge. The system is built around OpenBao (open-source Vault fork) as the central secrets vault, with External Secrets Operator enabling seamless integration with Kubernetes workloads.

## Architecture Diagram

```mermaid
graph TB
    %% Styling
    classDef vault fill:#4B8BBE,stroke:#306998,stroke-width:3px,color:#fff
    classDef k8s fill:#326CE5,stroke:#00308F,stroke-width:2px,color:#fff
    classDef app fill:#00D084,stroke:#00A86B,stroke-width:2px,color:#fff
    classDef external fill:#FF6B6B,stroke:#C92A2A,stroke-width:2px,color:#fff
    classDef cron fill:#FFA500,stroke:#FF8C00,stroke-width:2px,color:#fff

    %% OpenBao Core
    subgraph OpenBao["OpenBao Vault Cluster (cf-openbao namespace)"]
        BAO0[OpenBao-0<br/>Leader]:::vault
        BAO1[OpenBao-1<br/>Follower]:::vault
        BAO2[OpenBao-2<br/>Follower]:::vault
        
        BAO0 -.Raft Replication.-> BAO1
        BAO0 -.Raft Replication.-> BAO2
        
        subgraph Storage["Raft Integrated Storage"]
            RAFT[Persistent Volumes<br/>Raft Consensus]:::vault
        end
        
        subgraph Auth["Authentication"]
            USERPASS[UserPass Auth<br/>readonly-user]:::vault
        end
        
        subgraph Secrets["Secret Engines"]
            KV2[KV v2: secrets/*<br/>Generated Credentials]:::vault
            APIKEY[KV v2: apikey-groups/*<br/>API Keys]:::vault
            RANDOM[sys/tools/random<br/>Password Generator]:::vault
        end
        
        BAO0 --> RAFT
        BAO1 --> RAFT
        BAO2 --> RAFT
        BAO0 --> Auth
        BAO0 --> Secrets
    end

    %% Bootstrap Process
    subgraph Bootstrap["Bootstrap Process (bootstrap.sh)"]
        INIT[1. Init OpenBao<br/>Generate Keys]:::cron
        UNSEAL[2. Unseal All Pods<br/>Join Raft Cluster]:::cron
        SETUP[3. Setup Auth & Engines<br/>Create read-policy]:::cron
        GENSEC[4. Generate Secrets<br/>Random Passwords]:::cron
        
        INIT --> UNSEAL
        UNSEAL --> SETUP
        SETUP --> GENSEC
    end

    %% Unseal Automation
    subgraph UnsealAuto["Automated Unseal (CronJob)"]
        CRONJOB[openbao-unseal-job<br/>Runs every 5 minutes]:::cron
        UNSEALSCRIPT[Unseal Script<br/>Checks sealed pods]:::cron
        
        CRONJOB --> UNSEALSCRIPT
    end

    %% Kubernetes Secrets
    subgraph K8sSecrets["Kubernetes Secrets Storage"]
        BAOKEYS[openbao-keys<br/>root_token, unseal_key]:::k8s
        BAOUSER[openbao-user<br/>readonly credentials]:::k8s
        GITEAADMIN[gitea-admin-credentials<br/>bootstrap admin]:::k8s
    end

    %% External Secrets Operator
    subgraph ESO["External Secrets Operator (external-secrets namespace)"]
        ESOCTRL[ES Controller]:::external
        ESOWH[ES Webhook]:::external
        ESOCERT[ES Cert Controller]:::external
        
        ESOCTRL -.Watches.-> ESOWH
        ESOCERT -.Manages.-> ESOWH
    end

    %% ClusterSecretStores
    subgraph CSS["ClusterSecretStores"]
        CSS1[openbao-secret-store<br/>UserPass Auth<br/>path: secrets/]:::external
        CSS2[k8s-secret-store<br/>K8s SA Auth<br/>backend: cf-es-backend]:::external
        CSS3[airm-secret-store<br/>Points to OpenBao]:::external
        CSS4[k8srealm-secret-store<br/>For Keycloak]:::external
        CSS5[fake-secret-store<br/>Testing/Defaults]:::external
    end

    %% Application ExternalSecrets
    subgraph AppSecrets["Application ExternalSecrets"]
        ES1[keycloak-credentials]:::app
        ES2[airm-realm-credentials]:::app
        ES3[k8s-realm-credentials]:::app
        ES4[minio-tenant secrets]:::app
        ES5[cnpg database credentials]:::app
        ES6[rabbitmq credentials]:::app
    end

    %% Applications
    subgraph Apps["Applications"]
        KC[Keycloak<br/>Identity Provider]:::app
        GITEA[Gitea<br/>Git Server]:::app
        MINIO[MinIO<br/>Object Storage]:::app
        CNPG[CloudNativePG<br/>Databases]:::app
        RABBIT[RabbitMQ<br/>Message Queue]:::app
    end

    %% Flow connections
    Bootstrap --> BAO0
    Bootstrap --> K8sSecrets
    
    K8sSecrets --> UnsealAuto
    UnsealAuto --> BAO0
    UnsealAuto --> BAO1
    UnsealAuto --> BAO2
    
    BAO0 --> CSS1
    BAO0 --> CSS3
    BAO0 --> CSS4
    K8sSecrets --> CSS2
    
    CSS1 -.Authenticates via.-> USERPASS
    CSS1 -.Reads from.-> KV2
    
    ESO --> CSS1
    ESO --> CSS2
    ESO --> CSS3
    ESO --> CSS4
    ESO --> CSS5
    
    CSS1 --> AppSecrets
    CSS2 --> AppSecrets
    CSS3 --> AppSecrets
    CSS4 --> AppSecrets
    
    AppSecrets --> KC
    AppSecrets --> GITEA
    AppSecrets --> MINIO
    AppSecrets --> CNPG
    AppSecrets --> RABBIT
    
    BAOUSER -.Contains credentials for.-> CSS1
    BAOKEYS -.Unseals.-> BAO0
    BAOKEYS -.Unseals.-> BAO1
    BAOKEYS -.Unseals.-> BAO2

    %% Secret Generation Flow
    RANDOM -.Generates.-> KV2
    RANDOM -.Generates.-> APIKEY
```

## Key Components

### 1. OpenBao Vault Cluster

**Deployment Model:**
- 3-node cluster in High Availability (HA) mode
- Raft integrated storage (no external dependencies)
- Each pod runs in `cf-openbao` namespace
- Auto-unseal via CronJob every 5 minutes

**Configuration:**
```yaml
Storage: Raft integrated
UI: Enabled
Auth Methods: userpass
Secret Engines: 
  - secrets/ (KV v2) - Application secrets
  - apikey-groups/ (KV v2) - API key management
  - sys/tools/random - Password generation
```

### 2. Bootstrap Process

**init-openbao.sh:**
1. Checks if OpenBao is already initialized
2. Initializes with key-shares=1, key-threshold=1 (single key setup)
3. Stores `root_token` and `unseal_key` in K8s secret `openbao-keys`
4. Unseals all 3 pods
5. Forms Raft cluster (pods join via HTTP)

**setup-openbao.sh:**
1. Enables KV v2 engines at `secrets/` and `apikey-groups/`
2. Enables `userpass` authentication
3. Creates `read-policy` for read-only access
4. Creates `readonly-user` with read-only permissions
5. Stores readonly credentials in K8s secret `openbao-user`

**generate-secrets.sh:**
Generates all application secrets using OpenBao's random generator:
- Database credentials (Keycloak, AIRM, Catalog)
- RabbitMQ user credentials
- MinIO access keys and secrets
- OAuth client secrets (Gitea, ArgoCD, K8s realm)
- Keycloak admin passwords
- Cluster authentication tokens

### 3. Automated Unseal Mechanism

**CronJob Configuration:**
- Schedule: Every 5 minutes (`*/5 * * * *`)
- Runs in `cf-openbao` namespace
- Service Account: `openbao-unseal-job-sa`
- Permissions: Get pods, exec into pods, read secrets

**Unseal Logic:**
1. Retrieves `unseal_key` from `openbao-keys` secret
2. Finds all running OpenBao pods that are sealed
3. Executes `bao operator unseal` on each sealed pod
4. Handles pod restarts and cluster member changes

### 4. External Secrets Operator

**Components:**
- **Controller**: Watches ExternalSecret resources and syncs from backends
- **Webhook**: Validates ExternalSecret/SecretStore resources
- **Cert Controller**: Manages TLS certificates for webhooks

**ClusterSecretStore Types:**

1. **openbao-secret-store**
   - Provider: OpenBao (vault)
   - Auth: UserPass (readonly-user)
   - Path: secrets/
   - Used by: Most application secrets

2. **k8s-secret-store**
   - Provider: Kubernetes
   - Auth: Service Account (external-secrets-readonly)
   - Backend: cf-es-backend namespace
   - Used by: Cross-namespace secret sharing

3. **airm-secret-store** / **k8srealm-secret-store**
   - Domain-specific stores for AIRM and K8s realm
   - Point to OpenBao with specific paths

4. **fake-secret-store**
   - Provider: Fake (hardcoded values)
   - Used for: Testing and default values

### 5. Secret Flow Architecture

```
┌─────────────────┐
│ Bootstrap Script│
└────────┬────────┘
         │ 1. Initialize
         ▼
┌─────────────────┐
│  OpenBao Vault  │◄─── Unseals every 5min
│   (3 replicas)  │
└────────┬────────┘
         │ 2. Store secrets
         ▼
┌─────────────────┐
│ KV v2 Engine    │
│  secrets/*      │
└────────┬────────┘
         │ 3. External Secrets reads
         ▼
┌──────────────────────┐
│ ClusterSecretStore   │
│ (openbao-secret-store)│
└────────┬─────────────┘
         │ 4. Sync to K8s
         ▼
┌─────────────────┐
│ ExternalSecret  │
│   Resources     │
└────────┬────────┘
         │ 5. Creates K8s Secret
         ▼
┌─────────────────┐
│ Application Pod │
│ (mounts secret) │
└─────────────────┘
```

### 6. Secret Categories

**Identity & Authentication:**
- Keycloak admin password
- OAuth client secrets (Gitea, ArgoCD, AIRM UI)
- Realm credentials (AIRM, K8s)

**Database Credentials:**
- PostgreSQL superuser & user credentials (AIRM, Keycloak, Catalog)
- Generated via OpenBao random tool
- Managed by CloudNativePG operator

**Storage & Messaging:**
- MinIO root password, API keys, console keys
- MinIO OpenID Connect URLs
- RabbitMQ user credentials

**Cluster Infrastructure:**
- Cluster admin tokens
- OpenBao root token (stored in K8s)
- Domain configuration

### 7. Security Model

**Encryption at Rest:**
- OpenBao data encrypted in Raft storage
- Kubernetes secrets encrypted if cluster encryption is enabled

**Access Control:**
- **Root Token**: Stored in K8s secret, used only during bootstrap
- **Readonly User**: Limited to read operations on secrets path
- **Service Accounts**: Scoped to specific namespaces

**Network Security:**
- OpenBao accessible only within cluster (ClusterIP)
- TLS disabled for internal communication (cluster-internal)
- External Secrets uses internal service DNS

**Secret Rotation:**
- OpenBao supports secret versioning (KV v2)
- Applications can reference specific versions
- Old versions retained for rollback

### 8. Disaster Recovery

**Backup Strategy:**
- OpenBao unseal key stored in `openbao-keys` K8s secret
- Root token stored in `openbao-keys` K8s secret
- Raft storage on persistent volumes

**Recovery Process:**
1. Restore persistent volumes with Raft data
2. Deploy OpenBao pods
3. Unseal using stored unseal key
4. Verify cluster health via `bao operator raft list-peers`

**Important Notes:**
- Single unseal key (key-shares=1) - simplified but less secure
- For production, use Shamir's Secret Sharing (key-shares=5, threshold=3)
- Consider auto-unseal with cloud KMS for production

### 9. Integration Points

**Gitea Configuration:**
- Admin credentials generated during bootstrap
- OAuth client secret from OpenBao
- Integrated with Keycloak via OIDC

**Keycloak Realms:**
- Two realms: `airm` and `k8s`
- Client secrets managed in OpenBao
- Realm templates with placeholder substitution

**CloudNativePG:**
- Superuser and application user credentials
- Secrets created before cluster bootstrap
- Automatic database initialization

**MinIO Tenant:**
- Console and API credentials separate
- OIDC integration with Keycloak
- Auto-configured with OpenBao secrets

## Monitoring & Observability

**Health Checks:**
- OpenBao: `bao status` via exec probe
- External Secrets: Controller logs and metrics
- Secret Sync: ExternalSecret CR status conditions

**Common Issues:**
- **Sealed Vault**: Check CronJob execution and unseal key
- **Secret Sync Failure**: Verify ClusterSecretStore authentication
- **Missing Secrets**: Check OpenBao path and ExternalSecret remoteRef

## Best Practices

1. **Never commit unseal keys or root tokens** to version control
2. **Rotate readonly user credentials** periodically
3. **Monitor ExternalSecret sync errors** for failed secret updates
4. **Use specific secret versions** in production for stability
5. **Test secret rotation** in staging before production
6. **Backup `openbao-keys` secret** to secure external location
7. **Enable audit logging** in OpenBao for compliance
8. **Use namespaced SecretStores** for tenant isolation when possible

## Future Enhancements

- [ ] Implement auto-unseal with cloud KMS
- [ ] Add secret rotation automation
- [ ] Enable OpenBao audit logging
- [ ] Implement Shamir's Secret Sharing (N-of-M keys)
- [ ] Add monitoring/alerting for unsealed state
- [ ] Integrate with cert-manager for TLS
- [ ] Add RBAC policies for fine-grained access
- [ ] Implement secret versioning strategy
