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

### Workflow

Cluster-Forge deploys all necessary components within the cluster using GitOps-controller [ArgoCD](https://argo-cd.readthedocs.io/)
and [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) where Cluster-Forge itself acts as an app of apps.

### Components

Cluster-Forge repository file structure has 3 main folders:

- scripts - bash scripts to [bootstrap](./scripts/bootstrap.md) necessary prerequisite components for Cluster-Forge & install it
- root - core component, root helm chart for app-of-apps that creates all other ArgoCD applications into k8s cluster
- sources - folder that contains third-party, community and in-house helm charts & kubernetes manifests that represent cluster components

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

**Storage & Database:**
- **CNPG Operator** - Cloud-native PostgreSQL management
- **MinIO Operator + Tenant** - S3-compatible object storage

#### Layer 3: AI/ML Compute Stack
**GPU & Compute:**
- **AMD GPU Operator** - GPU device management and drivers
- **KubeRay Operator** - Ray distributed computing framework
- **KServe + CRDs** - Kubernetes-native model serving
- **Kueue** - Advanced job queueing system
- **AppWrapper** - Application scheduling and resource management

**Workflow & Orchestration:**
- **Kaiwo + CRDs** - Workflow management system
- **RabbitMQ** - Message broker for async processing

#### Layer 4: Observability & Monitoring
- **Prometheus Operator CRDs** - Metrics collection infrastructure
- **OpenTelemetry Operator** - Distributed tracing and telemetry
- **OTEL-LGTM Stack** - Unified observability platform (Loki, Grafana, Tempo, Mimir)

#### Layer 5: Identity & Access
- **Keycloak** - Enterprise identity and access management
- **Cluster-Auth** - Kubernetes RBAC integration
- **Kyverno** - Policy engine for security governance

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
- Support external configuration via Git repository
- Enable continuous deployment and sync capabilities

**FR3: Dependency Management**
- Deploy components in correct dependency order
- Validate component health before proceeding
- Handle complex inter-component dependencies automatically
- Support component customization through values files

### Non-Functional Requirements

- Single-command bootstrap deployment
- Complete platform deployment in under 30 minutes
- Provide HA-configuration for all critical components
