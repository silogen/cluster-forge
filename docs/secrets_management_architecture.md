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

**manage-secrets.sh (NEW - Unified Secret Management):**
Replaces the old hardcoded `generate-secrets.sh` with a declarative, config-driven approach:
1. Reads secret definitions from `openbao-secret-definitions.yaml` ConfigMap
2. Supports two secret types:
   - `static`: Fixed values with domain templating support (e.g., `{{ .Values.domain }}`)
   - `random`: Generated using OpenBao's random tool with specified byte length
3. Uses format: `SECRET_PATH|TYPE|VALUE|BYTES` (e.g., `secrets/my-app-password|random||32`)
4. Idempotent operation - skips existing secrets, only creates missing ones
5. Handles domain templating with `envsubst` for static values
6. Special handling for `cluster-auth-openbao-token` in init mode
7. Used by both bootstrap process and ongoing CronJob management
8. Comprehensive error handling and progress reporting instead of generate-secrets.sh.

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

### 4. Automated Secret Management System

**Declarative Secret Definition System:**
- **Location**: `sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml`
- **Format**: Structured ConfigMap with pipe-delimited entries: `SECRET_PATH|TYPE|VALUE|BYTES`
- **Configuration Management**: Deployed as Helm chart enabling GitOps-based secret management
- **Domain Templating**: Static values support `{{ .Values.domain }}` templating for environment-specific configuration

**Secret Types Supported:**
1. **Static Secrets**: 
   - Format: `secrets/cluster-domain|static|{{ .Values.domain }}|0`
   - Use case: Fixed values, URLs, domain references
   - Supports Helm templating for dynamic values
2. **Random Secrets**:
   - Format: `secrets/my-app-password|random||32`
   - Use case: Generated passwords, tokens, API keys
   - Byte length specified in fourth field

**CronJob-Based Management:**
- **Schedule**: Every 5 minutes (`*/5 * * * *`)
- **Purpose**: Ensures all defined secrets exist in OpenBao without manual intervention
- **Behavior**: Idempotent - only creates missing secrets, skips existing ones
- **Template**: `sources/openbao-config/0.1.0/templates/openbao-secret-manager-cronjob.yaml`
- **Service Account**: `openbao-secret-manager-sa` with minimal required permissions
- **Timeout**: 5-minute active deadline with single retry on failure

**Configuration Management Features:**
- **Checksum Annotations**: Forces pod recreation when ConfigMap changes
- **Resource Limits**: Memory: 256Mi, CPU: 500m for controlled resource usage
- **Environment Variables**: Domain templating via Helm values injection
- **Volume Mounts**: Scripts from `openbao-secret-manager-scripts`, config from `openbao-secrets-config`

**Adding New Secrets Workflow:**
1. Edit `sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml`
2. Add line following format: `secrets/my-app-password|random||32`
3. Commit and push to main branch
4. ArgoCD syncs the configuration within ~3 minutes
5. CronJob automatically creates the secret within ~5 minutes
6. Total time from commit to secret availability: ~8 minutes

**For detailed user guide:** See [secret management user guide](secret-management-user-guide.md) for step-by-step instructions and examples

**Examples from Current Configuration:**
```
# Database credentials
secrets/airm-cnpg-user-password|random||16

# Static domain-based URLs
secrets/minio-openid-url|static|https://kc.{{ .Values.domain }}/realms/airm/.well-known/openid-configuration|0

# Fixed API keys
secrets/minio-api-access-key|static|api-default-user|0
```

### 5. External Secrets Operator

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

### 6. Secret Flow Architecture

```mermaid
flowchart TD
    %% Styling
    classDef bootstrap fill:#FFE066,stroke:#FFB800,stroke-width:3px,color:#000
    classDef vault fill:#4B8BBE,stroke:#306998,stroke-width:3px,color:#fff
    classDef config fill:#9B59B6,stroke:#8E44AD,stroke-width:2px,color:#fff
    classDef k8s fill:#326CE5,stroke:#00308F,stroke-width:2px,color:#fff
    classDef app fill:#00D084,stroke:#00A86B,stroke-width:2px,color:#fff
    classDef external fill:#FF6B6B,stroke:#C92A2A,stroke-width:2px,color:#fff

    %% Main flow
    A[Bootstrap Script<br/>1. Deploy openbao-config<br/>2. Initialize OpenBao]:::bootstrap
    B[OpenBao Vault Cluster<br/>3 replicas<br/>Unseals every 5min]:::vault
    C[Automated Management<br/>CronJob every 5min<br/>- Reads config<br/>- Creates missing<br/>- Skips existing]:::config
    D["Secret Definition<br/>ConfigMap Helm<br/>- Format: PATH|TYPE|...<br/>- Domain templating<br/>- GitOps managed"]:::config
    E[KV v2 Engine<br/>secrets/* in OpenBao]:::vault
    F[ClusterSecretStore<br/>openbao-secret-store]:::external
    G[ExternalSecret<br/>Resources]:::k8s
    H[Application Pod<br/>mounts secret]:::app

    %% Flow connections with labels
    A -->|1. Deploys| B
    A -->|1. Creates| D
    D -->|3. Monitors definitions| C
    C -->|2. Config-driven secret creation| B
    B -->|4. Secrets stored| E
    E -->|5. External Secrets reads| F
    F -->|6. Sync to K8s| G
    G -->|7. Creates K8s Secret| H

    %% Feedback loop
    C -.->|Monitors ConfigMap| D
```

### 7. Secret Categories

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

### 8. Security Model

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

### 9. Disaster Recovery

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

### 10. Integration Points

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
