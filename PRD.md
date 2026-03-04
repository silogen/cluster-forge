# Cluster-Forge Product Requirements Document (PRD)

## Executive Summary

**Cluster-Forge** is a Kubernetes platform automation tool that bundles third-party, community, and in-house components into a single, GitOps-managed stack deployable in Kubernetes clusters. It automates the deployment of a complete AI/ML compute platform built on AMD Enterprise AI Suite components, delivering consistent, production-ready clusters with all essential services pre-configured and integrated.

The platform uses ArgoCD's app-of-apps pattern with a sophisticated bootstrap process that establishes GitOps infrastructure (ArgoCD, Gitea, OpenBao) before deploying the complete application stack.

## Target Users

- **AI/ML Engineers** - Unified platform for model training, serving, and orchestration
- **Platform Engineers** - Infrastructure automation with GitOps patterns
- **DevOps Engineers** - Consistent deployment across environments
- **Infrastructure Engineers** - Multi-cluster management and operations
- **Site Reliability Engineers** - Observability and reliability tooling
- **Research Teams** - Ephemeral test clusters for experimentation

## Product Architecture

### Bootstrap-First Deployment Model

Cluster-Forge uses a three-phase bootstrap process that establishes GitOps infrastructure before deploying applications:

**Phase 1: Pre-Cleanup**
- Detects and removes previous installations when gitea-init-job completed successfully
- Deletes Gitea resources, OpenBao init jobs, and temporary files
- Ensures clean state for fresh deployments

**Phase 2: GitOps Foundation Bootstrap** (Manual Helm Templates)
1. **ArgoCD** (v8.3.5) - GitOps controller deployed via helm template + kubectl apply
2. **OpenBao** (v0.18.2) - Secrets management with init job to configure vault, policies, and initial secrets
3. **Gitea** (v12.3.0) - Git server with init job to create cluster-forge and cluster-values repositories

**Phase 3: App-of-Apps Deployment** (ArgoCD-Managed)
- Creates cluster-forge Application pointing to root/ helm chart
- ArgoCD syncs and manages all remaining applications from enabledApps list
- Applications deployed in wave order (-5 to 0) based on dependencies

### Dual Repository GitOps Pattern

Cluster-Forge supports flexible GitOps repository configurations:

**Local Mode (Default)** - Self-contained cluster-native GitOps:
- `clusterForge.repoUrl`: Points to local Gitea (http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git)
- `externalValues.enabled: true`: Separate cluster-values repository for configuration
- Initialization handled by gitea-init-job which clones and pushes repositories from initial-cf-values ConfigMap
- Zero external dependencies once bootstrapped

**External Mode** - Traditional GitHub-based GitOps:
- Set `clusterForge.repoUrl` to external GitHub repository
- Supports custom branch selection for testing and development

### Size-Aware Configuration

Three cluster profiles with inheritance-based resource optimization:

**Small Clusters** (1-5 users, dev/test):
- Single replica deployments (ArgoCD, Redis, etc.)
- Reduced resource limits (ArgoCD controller: 2 CPU, 4Gi RAM)
- Adds kyverno-policies-storage-local-path for RWX→RWO PVC mutation
- MinIO tenant: 250Gi storage, single server
- Suitable for: Local workstations, development environments

**Medium Clusters** (5-20 users, team production):
- Single replica with moderate resource allocation
- Same storage policies as small (local-path support)
- ArgoCD controller: 2 CPU, 4Gi RAM
- Default configuration for balanced performance
- Suitable for: Small teams, staging environments

**Large Clusters** (10s-100s users, enterprise scale):
- OpenBao HA: 3 replicas with Raft consensus
- No local-path policies (assumes distributed storage like Longhorn)
- MinIO tenant: 500Gi storage
- Production-grade resource allocation
- Suitable for: Production deployments, multi-tenant environments

Size configurations use YAML merge semantics where size-specific values override base values.yaml settings.

### App-of-Apps Architecture

Cluster-Forge root chart generates ArgoCD Application manifests from:
- `enabledApps[]` - List of applications to deploy
- `apps.<name>` - Configuration for each application including:
  - `path` - Relative path in sources/ directory
  - `namespace` - Target Kubernetes namespace
  - `syncWave` - Deployment order (-5 to 0)
  - `valuesObject` - Inline Helm values
  - `helmParameters` - Templated Helm parameters (e.g., domain injection)
  - `ignoreDifferences` - ArgoCD diff exclusions

The cluster-forge Application uses multi-source feature when externalValues.enabled=true:
- Source 1: cluster-forge repo (root/ helm chart)
- Source 2: cluster-values repo (custom values.yaml)
- Merges: base values.yaml + size values + external cluster-values/values.yaml

### Component Categories

**Layer 1: GitOps Foundation** (Sync Wave -4 to -3)
- ArgoCD 8.3.5 - GitOps continuous deployment controller
- Gitea 12.3.0 - Self-hosted Git server with SQLite backend
- OpenBao 0.18.2 - Vault-compatible secrets management
- External Secrets 0.15.1 - Secrets synchronization operator

**Layer 2: Core Infrastructure** (Sync Wave -5 to -2)

*Networking:*
- Gateway API v1.3.0 - Kubernetes standard ingress API
- KGateway v2.1.0-main - Gateway API implementation with custom WebSocket support
- MetalLB v0.15.2 - Bare metal load balancer
- Cert-Manager v1.18.2 - Automated TLS certificate management

*Policy & Security:*
- Kyverno 3.5.1 - Policy engine for admission control
- Kyverno Config - OIDC integration, policy configurations
- Kyverno Policies Base - Core security policies
- Kyverno Policies Storage-Local-Path - Access mode mutation (small/medium only)
- Cluster-Auth 0.5.0 - Kubernetes RBAC integration

*Storage & Database:*
- CNPG Operator 0.26.0 - CloudNativePG PostgreSQL operator
- MinIO Operator 7.1.1 - S3-compatible object storage operator
- MinIO Tenant 7.1.1 - Tenant deployment with default-bucket and models buckets

**Layer 3: Observability** (Sync Wave -5 to -2)
- Prometheus Operator CRDs 23.0.0 - Metrics infrastructure
- OpenTelemetry Operator 0.93.1 - Telemetry collection with contrib collector
- OTEL-LGTM Stack v1.0.7 - Integrated observability (Loki, Grafana, Tempo, Mimir)
  - Storage: 50Gi each for tempo/loki/mimir, 10Gi grafana
  - Metrics collector: 8Gi RAM, 2 CPU
  - Logs collector daemonset: 2Gi RAM, 1 CPU

**Layer 4: Identity & Access** (Sync Wave -1 to 0)
- Keycloak (keycloak-old chart) - Enterprise IAM with AIRM realm
  - Custom extensions via init containers (SilogenExtensionPackage.jar)
  - Realm import with domain-group-authenticator
  - Client secrets for: AIRM, K8s, MinIO, Gitea, ArgoCD

**Layer 5: AI/ML Compute Stack** (Sync Wave -3 to 0)

*GPU & Scheduling:*
- AMD GPU Operator v1.4.1 - GPU device plugin and drivers
- KubeRay Operator 1.4.2 - Ray distributed computing framework
- Kueue 0.13.0 - Job queueing with multi-framework support
  - Integrations: batch/job, Ray, MPIJob, PyTorchJob, TensorFlow, Jobset, AppWrapper, Pod, Deployment
- AppWrapper v1.1.2 - Application-level resource scheduling
- KEDA 2.18.1 - Event-driven autoscaling
- Kedify-OTEL v0.0.6 - KEDA telemetry integration

*ML Serving & Inference:*
- KServe v0.16.0 - Model serving platform (Standard deployment mode)
- KServe CRDs v0.16.0 - Model serving custom resources

*Workflow & Messaging:*
- Kaiwo v0.2.0-rc11 - AI workload orchestration
- Kaiwo CRDs v0.2.0-rc11 - Workflow custom resources
- RabbitMQ v2.15.0 - Message broker for async processing

**Layer 6: AIRM Application** (Sync Wave 0)
- AIRM 0.3.2 - AMD Resource Manager application suite
- AIM Cluster Model Source - Cluster resource models for AIRM

### Repository Structure

```
cluster-forge/
├── scripts/
│   ├── bootstrap.sh              # Main bootstrap orchestration
│   ├── init-gitea-job/           # Helm chart for Gitea initialization
│   ├── init-openbao-job/         # Helm chart for OpenBao initialization
│   └── utils/                     # Backup/restore utilities
│       ├── export_databases.sh
│       ├── export_rabbitmq.sh
│       ├── import_databases.sh
│       ├── import_rabbitmq.sh
│       └── mirror_minio.sh
├── root/
│   ├── Chart.yaml                # ClusterForge root helm chart metadata
│   ├── values.yaml               # Base configuration
│   ├── values_small.yaml         # Small cluster overrides
│   ├── values_medium.yaml        # Medium cluster overrides
│   ├── values_large.yaml         # Large cluster overrides
│   └── templates/
│       ├── _helpers.yaml         # Template helper functions
│       ├── cluster-apps.yaml     # Generates ArgoCD Application per enabledApp
│       └── cluster-forge.yaml    # Self-managing ClusterForge Application
├── sources/                       # Versioned helm charts and configurations
│   ├── <component>/
│   │   ├── <version>/            # Upstream helm chart or Kustomize
│   │   ├── source.yaml           # Source metadata (optional)
│   │   └── values_ha.yaml        # HA overrides (optional)
│   └── <component-config>/       # Configuration helm charts
│       └── templates/            # ConfigMaps, Secrets, ExternalSecrets
├── docs/                          # Architecture and operational documentation
└── sbom/                          # Software bill of materials tooling
```

## Key Features

### Single-Command Bootstrap

The bootstrap.sh script orchestrates complete cluster setup:

```bash
./scripts/bootstrap.sh <domain> [--CLUSTER_SIZE=small|medium|large]
```

**Bootstrap Process:**
1. **Validation** - Checks domain, cluster size, values files, yq tool availability
2. **Pre-cleanup** - Removes previous installations if gitea-init-job completed
3. **Values Merge** - Combines base + size-specific values with domain injection
4. **Namespace Creation** - Creates argocd, cf-gitea, cf-openbao namespaces
5. **ArgoCD Deployment** - helm template + kubectl apply with server-side apply
6. **OpenBao Deployment** - helm template + kubectl apply, waits for pod ready
7. **OpenBao Init Job** - Configures vault policies, auth methods, initial secrets
8. **Gitea Deployment** - helm template + kubectl apply, waits for rollout
9. **Gitea Init Job** - Creates cluster-org, clones/pushes cluster-forge and cluster-values repos
10. **ClusterForge App** - Creates root Application with merged values
11. **Cleanup** - Removes temporary values files

### Self-Contained GitOps

Once bootstrapped, the cluster is fully self-sufficient:

**Local Git Server (Gitea):**
- Stores cluster-forge repository (platform code)
- Stores cluster-values repository (environment-specific configuration)
- Provides Git UI at https://gitea.{domain}
- Admin credentials in gitea-admin-credentials secret
- SQLite backend for lightweight operation

**Local Secrets Management (OpenBao):**
- Vault-compatible secrets engine
- Initialized with policies for each component
- Kubernetes auth method configured
- External Secrets Operator integration
- Secrets for: Keycloak clients, AIRM, database credentials, API keys

**Configuration as Code:**
- All platform configuration in cluster-values repo
- Changes trigger ArgoCD sync automatically
- Full audit trail through Git history
- Rollback capability via Git revert

### Values Inheritance System

Three-layer configuration merge:

1. **Base Layer** (values.yaml) - Common defaults for all sizes
2. **Size Layer** (values_{size}.yaml) - Size-specific overrides
3. **External Layer** (cluster-values/values.yaml) - Environment customization

```yaml
# Bootstrap merges: base <- size <- external
VALUES=$(yq eval-all '. as $item ireduce ({}; . * $item)' \
    values.yaml values_medium.yaml cluster-values/values.yaml)
```

**Size-Specific Behaviors:**

Small/Medium are single-node and have storage class mutation policies:
```yaml
enabledApps:
  - kyverno-policies-storage-local-path  # RWX→RWO mutation for local-path
```

Large enables Multi-Node and HA components:
```yaml
apps:
  openbao:
    valuesObject:
      server:
        ha:
          enabled: true
          replicas: 3
```

### Component Version Management

**Versioned Sources Structure:**
```
sources/argocd/
  ├── 8.3.5/          # Upstream helm chart
  ├── source.yaml     # Source metadata (upstream repo, version)
  └── values_ha.yaml  # Optional HA overrides
```

**Configuration Companions:**
Each major component has -config variant:
- argocd-config: OIDC integration, RBAC policies, ExternalSecrets
- gitea-config: Keycloak OAuth, repository templates
- openbao-config: Policy definitions, secret paths, initialization scripts
- minio-tenant-config: Bucket policies, user credentials, gateway routes

### Secrets Management Architecture

**Three-Tier Secrets System:**

1. **OpenBao (Source of Truth)**
   - KV v2 secrets engine at secret/
   - Policies per namespace: argocd-policy, airm-policy, gitea-policy, etc.
   - Kubernetes auth method for pod authentication

2. **External Secrets Operator (Synchronization)**
   - ExternalSecret resources in each namespace
   - SecretStore points to OpenBao with serviceAccountRef
   - Automatic sync from OpenBao → Kubernetes Secrets
   - Example: argocd-oidc-creds ExternalSecret → OIDC client secret

3. **Kubernetes Secrets (Consumption)**
   - Standard Kubernetes Secret objects
   - Referenced by pods via env, volumeMounts
   - Automatically updated when OpenBao source changes

**Bootstrap Secret Flow:**
- bootstrap.sh generates initial passwords with `openssl rand -hex 16`
- openbao-init-job writes secrets to OpenBao
- External Secrets Operator syncs to Kubernetes Secrets
- Applications consume via secret references

### Modular Policy System

Kyverno policies organized by concern:

**Base Policies** (kyverno-policies-base):
- Core security policies
- Resource quotas
- Label requirements

**Storage Policies** (kyverno-policies-storage-local-path):
- Access mode mutation: ReadWriteMany → ReadWriteOnce
- Only enabled for small/medium clusters with local-path storage
- Prevents PVC creation failures on non-distributed storage

**Custom Policies:**
- AIRM-specific policies included in airm chart
- Custom validations and mutations per application

### Backup and Restore Utilities

**Database Export/Import:**
```bash
scripts/utils/export_databases.sh   # PostgreSQL dumps from CNPG
scripts/utils/import_databases.sh   # Restore PostgreSQL databases
```

**Message Queue:**
```bash
scripts/utils/export_rabbitmq.sh    # RabbitMQ definitions and messages
scripts/utils/import_rabbitmq.sh    # Restore queues and exchanges
```

**Object Storage:**
```bash
scripts/utils/mirror_minio.sh       # MinIO bucket synchronization
```

### Observability Stack

**Integrated LGTM Platform:**
- **Loki** - Log aggregation with 50Gi storage
- **Grafana** - Visualization dashboards with 10Gi storage  
- **Tempo** - Distributed tracing with 50Gi storage
- **Mimir** - Prometheus metrics with 50Gi storage

**Automatic Collection:**
- Metrics collector deployment: 8Gi RAM, 2 CPU limits
- Logs collector daemonset: 2Gi RAM, 1 CPU per node
- OpenTelemetry contrib collector for advanced telemetry
- Node exporter and kube-state-metrics enabled by default

**Service Endpoints:**
- Grafana UI: Port 3000
- OTLP gRPC: Port 4317
- OTLP HTTP: Port 4318
- Prometheus: Port 9090
- Loki: Port 3100

### AI/ML Workload Support

**Multi-Framework Job Integration:**

Kueue manages scheduling for:
- Kubernetes batch/job
- Ray (RayJob, RayCluster)
- Kubeflow (MPIJob, PyTorchJob, TFJob, XGBoostJob, JAXJob, PaddleJob)
- AppWrapper for multi-pod applications
- Pod, Deployment, StatefulSet

**Resource Management:**
- Kueue ClusterQueues for resource pools
- LocalQueues per namespace
- ResourceFlavors for GPU/CPU quotas
- Cohort sharing across teams

**Model Serving:**
- KServe Standard deployment mode
- InferenceService CRD for models
- Auto-scaling with KEDA
- S3 model storage via MinIO

**GPU Support:**
- AMD GPU Operator for device plugin
- Automatic driver installation
- GPU metrics in Prometheus
- Scheduling via Kueue resource flavors

## Technical Requirements

### Prerequisites

**Kubernetes Cluster:**
- Kubernetes 1.33+ (configurable via bootstrap.sh KUBE_VERSION)
- kubectl with cluster-admin access
- Working storage class (local-path for small/medium, distributed for large)
- Sufficient resources per cluster size

**Networking:**
- Domain name or wildcard DNS (*.example.com or *.{ip}.nip.io)
- Ingress capability (Gateway API + KGateway deployed by ClusterForge)
- External LoadBalancer or MetalLB (deployed by ClusterForge)

**TLS Certificates:**
- cluster-tls secret in kgateway-system namespace
- Can be self-signed for development
- Production should use Cert-Manager with ACME

**Required Tools:**
- yq v4+ (YAML processor)
- helm 3.0+
- kubectl
- openssl (for password generation)

### Resource Requirements

**Small Cluster:**
- single node
- 250Gi+ total storage
- Local-path or hostPath storage class

**Medium Cluster:**
- single node
- 500Gi+ total storage
- Local-path or distributed storage

**Large Cluster:**
- multinode, HA / 3 node control plane 
- 1Ti+ total storage
- Distributed storage required (Storage appliances / cloud / Longhorn, Ceph, etc.)

### Functional Requirements

**FR1: AIRM Platform Delivery**
- Deploy AMD Resource Manager (AIRM) 0.3.2 with UI and API
- Provide model serving with KServe v0.16.0
- Support distributed computing via KubeRay Operator 1.4.2
- Enable workflow orchestration through Kaiwo v0.2.0-rc11
- Integrate AMD GPU Operator v1.4.1 for GPU resources

**FR2: GitOps Operations**
- Bootstrap ArgoCD 8.3.5 with single command
- Manage 40+ components as ArgoCD Applications
- Support multi-source Applications for values separation
- Enable local Gitea 12.3.0 for cluster-native GitOps

**FR3: Size-Aware Deployment** 
- Support small/medium/large configurations via --CLUSTER_SIZE flag
- Automatically merge size-specific values with base configuration
- Enable/disable components based on cluster size (e.g., HA modes)
- Apply appropriate policies per size (storage access modes)

**FR4: Secrets Management**
- Initialize OpenBao 0.18.2 with vault policies
- Configure External Secrets Operator 0.15.1 integration
- Generate and store all component credentials
- Sync secrets from OpenBao to Kubernetes automatically

**FR5: Dependency Orchestration**
- Deploy components in wave order (-5 to 0)
- Bootstrap foundation before app-of-apps (ArgoCD, OpenBao, Gitea)
- Wait for component health before proceeding
- Use ignoreDifferences for known drift patterns

### Non-Functional Requirements

**Performance:**
- Complete bootstrap in under 15 minutes (small cluster)
- ArgoCD sync time under 5 minutes for full stack
- Gitea init job completes in under 2 minutes

**Reliability:**
- OpenBao HA with 3 replicas and Raft (large clusters)
- ArgoCD automated sync with self-heal
- Server-side apply to prevent field manager conflicts

**Maintainability:**
- Single values file per cluster size
- DRY principle for configuration inheritance
- Versioned sources for reproducible deployments
- SBOM generation for supply chain security

**Usability:**
- Single-command deployment
- Helpful error messages with validation
- Progress indication during bootstrap
- Access URLs displayed on completion

## Development and Customization

### Adding New Components

1. Add chart to sources/{component}/{version}/
2. Define app configuration in values.yaml:
```yaml
apps:
  my-component:
    path: my-component/1.0.0
    namespace: my-namespace
    syncWave: -1
    valuesObject:
      # component values
```
3. Add to enabledApps list

### Custom Cluster Values

Create cluster-values repository with custom values.yaml:
```yaml
# Override any base configuration
global:
  domain: custom.example.com

apps:
  argocd:
    valuesObject:
      server:
        replicas: 3  # Custom override
```

### Size Configuration

Modify values_{size}.yaml to adjust resources:
- Change replica counts
- Adjust CPU/memory limits
- Enable/disable HA modes
- Add size-specific enabledApps

## Documentation

Detailed documentation in `/docs`:

- [Bootstrap Guide](docs/bootstrap_guide.md) - Deployment walkthrough
- [Cluster Size Configuration](docs/cluster_size_configuration.md) - Size planning
- [Values Inheritance Pattern](docs/values_inheritance_pattern.md) - GitOps configuration
- [Kyverno Modular Design](docs/kyverno_modular_design.md) - Policy architecture
- [Kyverno Access Mode Policy](docs/kyverno_access_mode_policy.md) - Storage policies
- [Backup and Restore](docs/backup_and_restore.md) - Data protection

## Software Bill of Materials (SBOM)

ClusterForge includes comprehensive SBOM tooling in `/sbom`:

**SBOM Files:**
- `components.yaml` - Canonical list of all components with versions, licenses, and metadata
- `SBOM-QUICK-GUIDE.md` - Guide for SBOM generation and validation

**Validation Scripts:**
- `validate-components-sync.sh` - Ensures components.yaml matches actual sources/
- `validate-enabled-apps.sh` - Validates enabledApps lists reference defined components
- `validate-metadata.sh` - Checks required metadata fields
- `validate-sync.sh` - Full validation suite

**Generation Scripts:**
- `generate-sbom.sh` - Generates SPDX/CycloneDX SBOM documents
- `generate-compare-components.sh` - Compares component versions
- `update_licenses.sh` - Updates license information

## Version Information

**Current Release:** v1.8.0-rc2

**Key Component Versions:**
- ArgoCD: 8.3.5
- Gitea: 12.3.0
- OpenBao: 0.18.2
- Keycloak: keycloak-old chart
- KServe: v0.16.0
- Kaiwo: v0.2.0-rc11
- AIRM: 0.3.2
- Kueue: 0.13.0
- AMD GPU Operator: v1.4.1
- OTEL-LGTM Stack: v1.0.7

## Support and Contribution

**Repository:** https://github.com/silogen/cluster-forge

**Issue Tracking:** Use GitHub Issues for bug reports and feature requests

**Maintainers:** ClusterForge Team

## License

See [LICENSE](LICENSE) and [NOTICE](NOTICE) files for licensing information.