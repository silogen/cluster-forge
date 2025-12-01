# Cluster-Forge Dependency Map
## From cluster-bloom Prerequisites to AIRM Platform

### Visual Dependency Flow

```mermaid
graph TB
    %% cluster-bloom Prerequisites
    subgraph CB["cluster-bloom Outputs (Prerequisites for CF)"]
        SC["Working Storage Class"]
        DN["Domain Name"]
        TLS["cluster-tls Secret<br/>(kgateway-system namespace)"]
    end
    
    %% Tools Required
    subgraph TOOLS["Required Tools"]
        KUBECTL["kubectl"]
        HELM["helm 3.0+"]
        SSL["openssl"]
    end
    
    %% Bootstrap Foundation (Layer 1)
    subgraph L1["Layer 1: Bootstrap Foundation"]
        ARGO["ArgoCD<br/>(GitOps Controller)"]
        GITEA["Gitea<br/>(Git Repository)"]
        OPENBAO["OpenBao<br/>(Secret Management)"]
    end
    
    %% Core Infrastructure (Layer 2)
    subgraph L2["Layer 2: Core Infrastructure"]
        subgraph NET["Networking & Security"]
            GWAPI["Gateway API"]
            KGWAY["KGateway"]
            CERT["cert-manager"]
            MLB["MetalLB"]
            EXTSEC["external-secrets"]
            KYV["Kyverno"]
        end
        subgraph STOR["Storage & Database"]
            CNPG["CNPG Operator"]
            MINIO_OP["MinIO Operator"]
            MINIO_TEN["MinIO Tenant"]
        end
    end
    
    %% AI/ML Stack (Layer 3)
    subgraph L3["Layer 3: AI/ML Compute Stack"]
        subgraph GPU["GPU & Compute"]
            AMD_GPU["AMD GPU Operator"]
            KUBERAY["KubeRay Operator"]
            KSERVE["KServe + CRDs"]
            KUEUE["Kueue"]
            APPW["AppWrapper"]
        end
        subgraph WF["Workflow & Messaging"]
            KAIWO["Kaiwo + CRDs"]
            RABBIT["RabbitMQ"]
        end
    end
    
    %% Observability (Layer 4)
    subgraph L4["Layer 4: Observability"]
        PROM["Prometheus CRDs"]
        OTEL["OpenTelemetry Operator"]
        LGTM["OTEL-LGTM Stack"]
    end
    
    %% Identity (Layer 5)  
    subgraph L5["Layer 5: Identity & Access"]
        KC["Keycloak"]
        AUTH["cluster-auth"]
    end
    
    %% AIRM Application (Final Deliverable)
    subgraph AIRM_APP["🎯 AIRM Platform (Main Deliverable)"]
        AIRM_UI["AIRM Frontend<br/>(Web Dashboard)"]
        AIRM_API["AIRM Backend<br/>(REST API)"]
        AIRM_DISP["AIRM Dispatcher<br/>(Job Scheduler)"]
    end
    
    %% Dependencies: cluster-bloom → CF Bootstrap
    SC --> ARGO
    SC --> CNPG
    SC --> MINIO_TEN
    DN --> ARGO
    DN --> KGWAY
    TLS --> KGWAY
    KUBECTL --> ARGO
    HELM --> ARGO
    SSL --> OPENBAO
    
    %% Bootstrap Dependencies
    ARGO --> GITEA
    ARGO --> OPENBAO
    
    %% Layer 1 → Layer 2
    OPENBAO --> EXTSEC
    ARGO --> CERT
    ARGO --> GWAPI
    ARGO --> MLB
    ARGO --> CNPG
    ARGO --> MINIO_OP
    
    %% Layer 2 → Layer 3
    CNPG --> RABBIT
    MINIO_OP --> MINIO_TEN
    GWAPI --> KGWAY
    CERT --> KGWAY
    ARGO --> AMD_GPU
    ARGO --> KUBERAY
    ARGO --> KSERVE
    ARGO --> KUEUE
    ARGO --> KAIWO
    
    %% Layer 2/3 → Layer 4
    ARGO --> PROM
    ARGO --> OTEL
    PROM --> LGTM
    OTEL --> LGTM
    
    %% Layer 2 → Layer 5
    ARGO --> KC
    ARGO --> AUTH
    
    %% All Layers → AIRM (Critical Dependencies)
    CNPG --> AIRM_API
    RABBIT --> AIRM_API
    RABBIT --> AIRM_DISP
    MINIO_TEN --> AIRM_API
    KC --> AIRM_API
    KC --> AIRM_UI
    OPENBAO --> AIRM_API
    EXTSEC --> AIRM_API
    KGWAY --> AIRM_UI
    KGWAY --> AIRM_API
    CERT --> AIRM_UI
    LGTM --> AIRM_API
    
    %% AI/ML Stack → AIRM (Compute Dependencies)
    AMD_GPU --> AIRM_DISP
    KUBERAY --> AIRM_DISP
    KSERVE --> AIRM_DISP
    KUEUE --> AIRM_DISP
    APPW --> AIRM_DISP
    KAIWO --> AIRM_DISP
    KYV --> AIRM_DISP
    AUTH --> AIRM_DISP
    
    %% Styling
    classDef prereq fill:#ffcccc,stroke:#ff6666,stroke-width:2px
    classDef bootstrap fill:#ccffcc,stroke:#66cc66,stroke-width:2px
    classDef infra fill:#ccccff,stroke:#6666ff,stroke-width:2px
    classDef aiml fill:#ffffcc,stroke:#cccc66,stroke-width:2px
    classDef obs fill:#ffccff,stroke:#cc66cc,stroke-width:2px
    classDef identity fill:#ccffff,stroke:#66cccc,stroke-width:2px
    classDef airm fill:#ff9999,stroke:#cc3333,stroke-width:3px
    
    class CB,TOOLS prereq
    class L1 bootstrap
    class L2 infra
    class L3 aiml
    class L4 obs
    class L5 identity
    class AIRM_APP airm
```

### Critical Dependency Paths

#### 🔴 **Critical Path 1: Data & Storage**
```
cluster-bloom Storage Class → CNPG Operator → PostgreSQL Database → AIRM Backend
cluster-bloom Storage Class → MinIO Operator → MinIO Tenant → AIRM Backend
```

#### 🔴 **Critical Path 2: Networking & Access**
```
cluster-bloom Domain + TLS → KGateway → AIRM Frontend/API Access
cert-manager → TLS Certificates → AIRM HTTPS Access
```

#### 🔴 **Critical Path 3: Authentication**
```
OpenBao → External Secrets → AIRM Credentials
Keycloak → AIRM User Authentication
```

#### 🔴 **Critical Path 4: Messaging & Jobs**
```
RabbitMQ → AIRM Dispatcher → AI/ML Job Scheduling
Kueue + AI/ML Operators → AIRM Job Execution
```

### Component Categories by AIRM Dependency

#### 🚨 **Hard Dependencies** (AIRM breaks without these)
- **Storage**: CNPG Operator, MinIO Operator/Tenant  
- **Networking**: Gateway API, KGateway, cert-manager
- **Security**: OpenBao, external-secrets, Keycloak
- **Messaging**: RabbitMQ
- **Foundation**: ArgoCD, Gitea

#### ⚡ **AI/ML Dependencies** (Reduced functionality without these)
- **Compute**: AMD GPU Operator, KubeRay Operator
- **Serving**: KServe + CRDs
- **Scheduling**: Kueue, AppWrapper
- **Workflows**: Kaiwo + CRDs
- **Policies**: Kyverno, cluster-auth

#### 📊 **Observability Dependencies** (Monitoring/debugging impacted)
- **Metrics**: Prometheus CRDs, OTEL-LGTM Stack
- **Telemetry**: OpenTelemetry Operator

#### 🔧 **Infrastructure Dependencies** (Platform functionality)
- **Load Balancing**: MetalLB
- **GitOps**: ArgoCD Applications for all components

### Deployment Order Summary

1. **Prerequisites**: cluster-bloom outputs must exist
2. **Bootstrap**: ArgoCD → Gitea → OpenBao  
3. **Infrastructure**: Operators for storage, networking, security
4. **AI/ML Stack**: GPU, compute, workflow operators
5. **AIRM Application**: Frontend, Backend, Dispatcher

### Failure Impact Analysis

| Missing Component | AIRM Impact |
|------------------|-------------|
| PostgreSQL (CNPG) | ❌ Complete failure - no database |
| RabbitMQ | ❌ No job scheduling/dispatch |
| MinIO | ❌ No data/model storage |
| Keycloak | ❌ No user authentication |
| KGateway | ❌ No external access |
| GPU Operators | ⚠️ No GPU workloads |
| KServe | ⚠️ No model serving |
| Monitoring Stack | ⚠️ No observability |