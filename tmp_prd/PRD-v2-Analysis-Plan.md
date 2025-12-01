# Cluster-Forge V2 Analysis & PRD Planning

## Analysis Summary

### Key Differences V1 vs V2

**V1 (Original PRD.md):**
- Complex Go-based tool with metallurgy-inspired workflow (Mine → Smelt → Customize → Cast → Forge)
- Container image creation with embedded manifests
- Manual component selection and processing
- Direct Kubernetes manifest deployment

**V2 (Current Implementation):**
- Simplified GitOps-first approach using Helm + ArgoCD bootstrap
- Bootstrap script (`scripts/bootstrap.sh`) deploys foundation components
- All applications managed as ArgoCD Applications via Helm charts
- GitOps workflow with Gitea for repository management

### V2 Architecture Overview

**Bootstrap Foundation (deployed first):**
1. **ArgoCD** - GitOps controller for continuous deployment
2. **Gitea** - Git repository server for GitOps source
3. **OpenBao** - Secret management system

**Application Stack (deployed via ArgoCD):**
- 50 total components orchestrated through `root/values_cf.yaml`
- All components deployed as Helm charts
- Dependency ordering managed through ArgoCD sync waves

### Main Deliverable: AIRM Platform

**AIRM (AI Resource Manager)** is the primary deliverable - an AI/ML platform that includes:
- Frontend and backend applications
- VLLM sidecar collector for LLM operations
- Elasticsearch for data storage
- RabbitMQ for message queuing
- Cluster runtime configuration
- HTTP routing and certificate management

**AIRM Versions Available:** 0.1.0, 0.2.0-0.2.7 (latest: 0.2.7)

### Dependencies for AIRM

**Core Infrastructure Foundation:**
- ArgoCD (GitOps orchestration)
- Gitea (source code management)
- OpenBao (secrets management)

**Network & Security Layer:**
- cert-manager (TLS certificate management)
- gateway-api (ingress specification)
- kgateway (gateway implementation)
- metallb (load balancing)
- external-secrets (external secret integration)
- keycloak (identity and access management)
- kyverno (policy engine)

**AI/ML Compute Stack:**
- amd-gpu-operator (GPU device management)
- kuberay-operator (Ray distributed computing)
- kserve (ML model serving)
- kueue (job queueing)
- appwrapper (application scheduling)

**Data & Storage:**
- minio-operator/tenant (object storage)
- cnpg-operator (PostgreSQL)
- rabbitmq (message broker)

**Observability:**
- prometheus-crds (metrics collection)
- opentelemetry-operator (telemetry)
- otel-lgtm-stack (observability stack)

**Workflow Management:**
- kaiwo (workflow orchestration)

### Prerequisites (handled by cluster-bloom)

**Required before cluster-forge deployment:**
- Working storage class
- Domain name configuration
- cluster-tls secret in kgateway-system namespace
- Kubernetes cluster with kubectl access
- Helm 3.0+
- OpenSSL

## Recommended Plan for PRD-v2.md

### Context Collection Strategy

**✅ Completed:**
- V1 PRD analysis
- V2 bootstrap process understanding
- Component structure analysis
- Dependency mapping

**🔄 Next Steps:**
- Examine AIRM helm chart structure and components
- Create detailed dependency flow diagram
- Identify AIRM-specific requirements and capabilities

### PRD-v2.md Structure

1. **Executive Summary**
   - Focus shift from general platform to AI/ML platform delivery
   - AIRM as primary product outcome
   - GitOps-first architecture

2. **Product Evolution**
   - V1→V2 transformation rationale
   - Simplified deployment model
   - Enhanced GitOps integration

3. **Architecture Overview**
   - Bootstrap-driven deployment
   - GitOps workflow with ArgoCD
   - Helm-based component management

4. **Core Deliverable: AIRM Platform**
   - AI Resource Manager capabilities
   - ML/AI workflow support
   - Integrated development environment

5. **Supporting Infrastructure**
   - Foundation services (GitOps, secrets, networking)
   - AI/ML compute stack
   - Data and storage layer
   - Observability and monitoring

6. **Prerequisites & Dependencies**
   - cluster-bloom requirements
   - External dependencies
   - Infrastructure requirements

7. **Deployment Process**
   - Bootstrap script workflow
   - ArgoCD application deployment
   - Configuration management

8. **Technical Requirements**
   - Updated functional requirements for V2
   - Performance characteristics
   - Security considerations

### Success Criteria

- Clear positioning of AIRM as primary deliverable
- Simplified architecture documentation
- Updated user stories focused on AI/ML use cases
- GitOps-centric operational model
- Dependency clarity for proper deployment sequencing

## Next Actions

1. Examine AIRM components in detail (`sources/airm/0.2.7/`)
2. Create dependency flow diagram
3. Draft PRD-v2.md with new structure
4. Review and refine content
5. Finalize PRD-v2.md document