# Cluster-Forge Product Requirements Document (PRD)

## Executive Summary

**Cluster-Forge** is a Kubernetes platform automation tool designed to bundle various third-party, community,
and in-house components into a single, streamlined stack that can be deployed in Kubernetes clusters.
By automating the deployment process, Cluster-Forge simplifies the creation of consistent, ready-to-use clusters
with all essential services pre-configured and integrated.

## Target Users

- **Infrastructure Engineers**
- **Platform Engineers**
- **DevOps Engineers**
- **Cloud Native Engineers**
- **Site Reliability Engineers**
- **AI/ML Engineers**

## Product Architecture

### Dual Repository GitOps Pattern

Cluster-Forge implements a sophisticated GitOps deployment pattern supporting both external GitHub deployment and local cluster-native deployment:

- **External Mode** (`values.yaml`): Traditional GitOps with GitHub dependency
- **Local Mode** (`values_cf.yaml`): Self-contained GitOps with local Gitea and separate configuration repository

See [Values Inheritance Pattern](docs/values_inheritance_pattern.md) for detailed documentation.

### Size-Aware Configuration

Cluster-Forge provides three pre-configured cluster profiles with streamlined inheritance:

- **Small Clusters** (1-5 users): Development/testing with minimal resources
- **Medium Clusters** (5-20 users): Team production workloads  
- **Large Clusters** (10s-100s users): Enterprise scale with full features

Size-specific configurations follow DRY principles, inheriting from base configuration and only overriding differences. See [Cluster Size Configuration](docs/cluster_size_configuration.md) for details.

### Workflow

Cluster-Forge deploys all necessary components within the cluster using GitOps-controller [ArgoCD](https://argo-cd.readthedocs.io/)
and [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) where Cluster-Forge itself acts as an app of apps.

### Components

Cluster-Forge repository file structure has 3 main folders:

- **scripts** - bash scripts to [bootstrap](docs/bootstrap_guide.md) necessary prerequisite components for Cluster-Forge & install it
- **root** - core component, root helm chart for app-of-apps that creates all other ArgoCD applications into k8s cluster
- **sources** - folder that contains third-party, community and in-house helm charts & kubernetes manifests that represent cluster components
- **docs** - comprehensive documentation covering architecture, configuration, and operational guides

So using the bootstrap script user deploys ArgoCD GitOps-controller and root application which then deploys other components into the cluster. 

Here are some key components that are being deployed:

#### Layer 1: GitOps Foundation (Bootstrap)
- **ArgoCD** - GitOps controller for continuous deployment
- **Gitea** - Git repository server for source management
- **OpenBao** - Vault-compatible secret management system

#### Layer 2: Core Infrastructure
**Networking & Security:**
- **Gateway API + KGateway** - Modern ingress and traffic management
- **Cert-Manager** - Automated TLS certificate management
- **MetalLB** - Load balancer for bare metal environments
- **External Secrets Operator** - External secret integration
- **Cilium** - Network security and observability
- **Kyverno** - Policy engine with modular policy system (see [Kyverno Modular Design](docs/kyverno_modular_design.md))

**Storage & Database:**
- **CNPG Operator** - Cloud-native PostgreSQL management
- **MinIO Operator + Tenant** - S3-compatible object storage
- **Longhorn** - Distributed block storage

#### Layer 3: Observability & Monitoring
- **Prometheus** - Metrics collection and alerting
- **Grafana** - Visualization and dashboarding  
- **Prometheus Operator CRDs** - Metrics collection infrastructure
- **OpenTelemetry Operator** - Distributed tracing and telemetry
- **OTEL-LGTM Stack** - Unified observability platform (Loki, Grafana, Tempo, Mimir)

#### Layer 4: AI/ML Compute Stack
**GPU & Compute:**
- **AMD GPU Operator** - GPU device management and drivers
- **KubeRay Operator** - Ray distributed computing framework
- **KServe + CRDs** - Kubernetes-native model serving
- **Kueue** - Advanced job queueing system
- **AppWrapper** - Application scheduling and resource management
- **KEDA** - Event-driven autoscaling

**Workflow & Orchestration:**
- **Kaiwo + CRDs** - Workflow management system
- **RabbitMQ** - Message broker for async processing

#### Layer 5: Identity & Access
- **Keycloak** - Enterprise identity and access management
- **Cluster-Auth** - Kubernetes RBAC integration

#### Layer 6: AIRM App
- **AIRM API** - The central API layer for AMD Resource Manager, handling authentication, access control, and cluster coordination.
- **AIRM UI** - The frontend interface to interact with resource management features, integrated with the AIRM API and authentication services.
- **AIRM Dispatcher** - The agent responsible for dispatching compute workloads to registered Kubernetes clusters and managing their lifecycle.

## Technical Requirements

### Prerequisites & Dependencies

#### External Dependencies
- **Kubernetes cluster** with kubectl access
- **Working storage class** for persistent volumes
- **Domain name configuration** for external access
- **cluster-tls secret** in kgateway-system namespace
- **Network connectivity** for image pulls and external services

#### Required Tools
- **Helm 3.0+** - Package management
- **kubectl** - Kubernetes CLI tool
- **OpenSSL** - Certificate and secret generation

### Functional Requirements

**FR1: AIRM Platform Delivery**
- Deploy complete AI/ML platform with web UI and API
- Provide model serving capabilities with KServe integration
- Support distributed computing with Ray operator
- Enable workflow orchestration through Kaiwo
- Integrate GPU resource management

**FR2: GitOps Operations**
- Bootstrap ArgoCD foundation with single script
- Manage all components as ArgoCD Applications
- Support both external GitHub and local Gitea repositories
- Enable continuous deployment and sync capabilities
- Provide developer access to cluster configuration via Git

**FR3: Size-Aware Deployment**
- Support small, medium, and large cluster configurations
- Implement automatic resource scaling based on cluster size
- Provide appropriate storage and access mode configurations per size
- Enable cluster-specific policy enforcement (e.g., [Kyverno Access Mode Policy](docs/kyverno_access_mode_policy.md))

**FR4: Dependency Management**
- Deploy components in correct dependency order
- Validate component health before proceeding
- Handle complex inter-component dependencies automatically
- Support component customization through values files

### Non-Functional Requirements

- Single-command bootstrap deployment
- Complete platform deployment in under 30 minutes
- Provide HA-configuration for all critical components
- Support air-gapped deployment scenarios
- Maintain configuration version control through Git
- Enable seamless transition from external to local repository management

## Documentation

Comprehensive documentation is available in the `/docs` folder:

- [Bootstrap Guide](docs/bootstrap_guide.md) - Step-by-step deployment instructions
- [Cluster Size Configuration](docs/cluster_size_configuration.md) - Small/medium/large cluster setup
- [Values Inheritance Pattern](docs/values_inheritance_pattern.md) - GitOps repository configuration
- [Kyverno Modular Design](docs/kyverno_modular_design.md) - Policy system architecture
- [Kyverno Access Mode Policy](docs/kyverno_access_mode_policy.md) - Storage compatibility policies
- [Secrets Management Architecture](docs/secrets_management_architecture.md) - Security implementation
- [Backup and Restore](docs/backup_and_restore.md) - Data protection procedures