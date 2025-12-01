# Product Requirements Document (PRD) - V2
## Cluster-Forge: AI/ML Platform Deployment System

### Executive Summary

**Cluster-Forge V2** is a GitOps-based deployment system that transforms bare Kubernetes clusters into fully-functional AI/ML platforms by deploying **AIRM (AI Resource Manager)** and all its supporting infrastructure. The system uses a bootstrap-driven approach to establish a complete GitOps foundation and deploy a comprehensive stack of 50+ integrated components that enable enterprise-grade AI/ML workflows.

### Product Evolution: V1 → V2

#### V1 Architecture (Legacy)
- Complex Go-based tool with metallurgy-inspired workflow (Mine → Smelt → Cast → Forge)
- Manual component selection and configuration processing
- Container image creation with embedded manifests
- Direct Kubernetes manifest deployment

#### V2 Architecture (Current)
- **GitOps-first approach** using ArgoCD and Helm charts
- **Bootstrap script** (`scripts/bootstrap.sh`) establishes foundation
- **All components deployed as ArgoCD Applications**
- **Simplified deployment model** focused on AIRM delivery

### Core Product: AIRM Platform

**AIRM (AI Resource Manager)** is the primary deliverable - a comprehensive AI/ML platform that provides:

#### User-Facing Capabilities
- **Web-based AI/ML Dashboard** - Frontend interface for managing AI workloads
- **REST API** - Backend services for programmatic access
- **Model Serving Infrastructure** - Deploy and serve ML models at scale
- **Distributed Computing** - Ray-based distributed AI/ML processing
- **Job Queue Management** - Intelligent scheduling of compute-intensive tasks
- **Workflow Orchestration** - End-to-end AI/ML pipeline management
- **GPU Resource Management** - Efficient allocation of GPU compute resources
- **Data Management** - Integrated storage and data pipeline capabilities

#### Technical Architecture
- **Frontend**: React-based UI (`amdenterpriseai/airm-ui:0.2.3`)
- **Backend**: API server (`amdenterpriseai/airm-api:0.2.3`) 
- **Dispatcher**: Workload scheduler (`amdenterpriseai/airm-dispatcher:0.2.3`)
- **Database**: PostgreSQL for application state
- **Message Queue**: RabbitMQ for async job processing
- **Storage**: MinIO for AI/ML datasets and models
- **Authentication**: Keycloak-based identity management
- **Observability**: VLLM sidecar collectors and metrics integration

### Supporting Infrastructure Stack

Cluster-Forge deploys **50 integrated components** organized in dependency layers to support AIRM:

#### Layer 1: GitOps Foundation (Bootstrap)
- **ArgoCD** - GitOps controller for continuous deployment
- **Gitea** - Git repository server for source management  
- **OpenBao** - Vault-compatible secret management system

#### Layer 2: Core Infrastructure
**Networking & Security:**
- **Gateway API + KGateway** - Modern ingress and traffic management
- **Cert-Manager** - Automated TLS certificate management
- **MetalLB** - Load balancer for bare metal environments
- **External Secrets + OpenBao Config** - External secret integration
- **Kyverno** - Policy engine for security governance

**Storage & Database:**
- **CNPG Operator** - Cloud-native PostgreSQL management
- **MinIO Operator + Tenant** - S3-compatible object storage
- **Storage Class Dependencies** - Persistent volume management

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

### Prerequisites & Dependencies

#### External Dependencies (Provided by cluster-bloom)
- **Kubernetes cluster** with kubectl access
- **Working storage class** for persistent volumes
- **Domain name configuration** for external access
- **cluster-tls secret** in kgateway-system namespace
- **Network connectivity** for image pulls and external services

#### Required Tools
- **Helm 3.0+** - Package management
- **kubectl** - Kubernetes CLI tool
- **OpenSSL** - Certificate and secret generation

#### Infrastructure Requirements
- **Minimum 3 nodes** for high availability
- **GPU nodes** for AI/ML workloads (AMD GPU recommended)
- **Sufficient storage** for databases, object storage, and models
- **Network policies** allowing inter-pod communication

### Deployment Process

#### Bootstrap Phase (scripts/bootstrap.sh)
```bash
./bootstrap.sh <domain> [values_file]
```

1. **Namespace Creation** - Creates core namespaces (argocd, cf-gitea, cf-openbao)
2. **ArgoCD Deployment** - GitOps controller with custom configuration
3. **Gitea Setup** - Git repository server with admin credentials
4. **OpenBao Initialization** - Secret management with automatic unsealing
5. **Application of Applications** - Root ArgoCD application managing all components

#### ArgoCD-Managed Deployment
- **Dependency Ordering** - Sync waves ensure proper component sequencing
- **Health Checks** - Automated validation of component readiness
- **Configuration Management** - External values repository for customization
- **Continuous Sync** - GitOps-driven updates and maintenance

#### Deployment Sequence
1. **Foundation Components** (ArgoCD, secrets, networking operators)
2. **Infrastructure Operators** (database, storage, compute operators)  
3. **AI/ML Stack** (GPU, Ray, KServe, workflow operators)
4. **AIRM Application** (frontend, backend, dispatcher)

### Target Users & Use Cases

#### Primary Users
- **ML Engineers** - Developing and deploying machine learning models
- **Data Scientists** - Running distributed data processing and model training
- **AI Researchers** - Conducting large-scale AI experiments and research
- **Platform Engineers** - Managing AI/ML infrastructure at scale

#### Secondary Users  
- **DevOps Teams** - Automating AI/ML deployment pipelines
- **Research Organizations** - Providing self-service AI/ML platforms
- **Enterprise AI Teams** - Building production AI applications

### User Stories & Scenarios

#### Epic 1: AI/ML Model Development
- **US1.1**: As an ML Engineer, I want to deploy trained models so that applications can consume AI predictions via REST APIs
- **US1.2**: As a Data Scientist, I want to run distributed training jobs so that I can train large models across multiple GPUs
- **US1.3**: As an AI Researcher, I want to schedule experiment workflows so that I can efficiently use compute resources

#### Epic 2: Platform Operations
- **US2.1**: As a Platform Engineer, I want to monitor AI workload performance so that I can optimize resource allocation
- **US2.2**: As a DevOps Engineer, I want GitOps deployment so that AI platform updates are automated and auditable  
- **US2.3**: As a Cluster Administrator, I want policy enforcement so that AI workloads comply with security standards

#### Epic 3: Self-Service AI Platform
- **US3.1**: As a Data Scientist, I want a web interface so that I can manage ML experiments without kubectl
- **US3.2**: As an ML Engineer, I want job queuing so that my training jobs run efficiently when resources are available
- **US3.3**: As a Research Team, I want shared storage so that we can collaborate on datasets and models

### Technical Requirements

#### Functional Requirements

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

**FR4: Security & Compliance**
- Integrate enterprise identity management (Keycloak)
- Enforce security policies with Kyverno
- Manage secrets securely with OpenBao
- Provide RBAC integration for Kubernetes resources

#### Non-Functional Requirements

**NFR1: Performance**
- Complete platform deployment in under 45 minutes
- Support clusters with 100+ nodes and multiple GPU types
- Handle concurrent AI/ML workloads efficiently
- Scale to enterprise workload demands

**NFR2: Reliability**
- Provide high availability for all critical components
- Support automated recovery from component failures
- Enable backup and restore capabilities for stateful services
- Maintain 99.9% uptime for AIRM platform services

**NFR3: Usability**
- Single-command bootstrap deployment
- Web-based interface for AI/ML workflow management
- Comprehensive documentation and examples
- Clear error messages and troubleshooting guides

**NFR4: Security**
- Follow Kubernetes security best practices
- Support enterprise authentication and authorization
- Enable audit logging for compliance requirements
- Provide vulnerability scanning and policy enforcement

### Success Metrics

#### Deployment Metrics
- **Time to Production**: < 45 minutes for complete platform deployment
- **Deployment Success Rate**: > 95% success rate for bootstrap process
- **Component Health**: 100% of critical components operational post-deployment

#### Platform Utilization
- **User Adoption**: Number of active AIRM platform users
- **Workload Metrics**: AI/ML jobs processed per day
- **Resource Efficiency**: GPU and compute utilization rates
- **Model Deployments**: Number of models served through KServe

#### Operational Metrics
- **Platform Reliability**: AIRM platform uptime percentage
- **Issue Resolution**: Mean time to resolution for platform issues
- **Documentation Quality**: User satisfaction with deployment guides

### Known Limitations & Considerations

#### Current Limitations
1. **GPU Dependency**: Optimized for AMD GPUs (limited NVIDIA support)
2. **Storage Requirements**: Requires pre-configured storage classes
3. **Network Dependencies**: Requires external domain and TLS configuration
4. **Resource Overhead**: Significant cluster resources required for full stack

#### Operational Considerations
1. **Cluster Size**: Minimum 3-node cluster recommended
2. **Resource Planning**: Plan for database, storage, and compute requirements
3. **Backup Strategy**: Implement backup procedures for stateful components
4. **Update Management**: Use GitOps workflow for platform updates

### Future Roadmap

#### Q1 2025: Foundation Enhancements
- Enhanced monitoring and alerting for AIRM components
- Automated backup and disaster recovery procedures
- Performance optimization for large-scale deployments
- Extended GPU support (NVIDIA integration)

#### Q2 2025: Advanced AI/ML Features
- Multi-tenant AIRM platform support
- Advanced workflow templates and examples
- Integration with external data sources and ML platforms
- Enhanced model management and versioning

#### Q3 2025: Enterprise Features
- Multi-cluster AIRM deployment support
- Advanced security and compliance features  
- Cost management and resource optimization tools
- Enterprise support and SLA offerings

#### Q4 2025: Ecosystem Integration
- Cloud provider optimizations (AWS, Azure, GCP)
- Integration with popular ML frameworks (MLflow, Kubeflow)
- Marketplace for pre-built AI/ML workflows
- Community contribution framework

### Conclusion

Cluster-Forge V2 represents a fundamental shift from a general-purpose platform tool to a specialized **AI/ML platform deployment system**. By focusing on AIRM as the primary deliverable and leveraging GitOps principles, V2 provides organizations with a streamlined path to production-ready AI/ML infrastructure.

The comprehensive dependency management, bootstrap-driven deployment, and integrated observability make Cluster-Forge V2 an essential tool for organizations seeking to rapidly deploy and scale AI/ML capabilities on Kubernetes. The system's modular architecture and GitOps foundation ensure long-term maintainability while providing immediate value through the complete AIRM platform delivery.