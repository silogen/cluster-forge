# AI Workbench (AIWB) Deployment and Pluggable Component Guide

This guide explains how to deploy AI Workbench on a Kubernetes cluster, including the base required components and optional pluggable components that can be substituted with your own implementations.

## Quick Start

To deploy AIWB with all reference components:

```bash
cd docs/manual_helm_install/scripts
./install_base.sh <DOMAIN>
```

**Examples:**
```bash
# Local testing
./install_base.sh localhost

# Production deployment
./install_base.sh example.com
```

The `DOMAIN` parameter is required and determines:
- For `localhost`: Uses HTTP on fixed ports (8080, 8000) for gateway routing
- For any other domain: Uses HTTPS with subdomain routing (e.g., `aiwbui.example.com`, `kc.example.com`)

## Table of Contents

- [Component Architecture Overview](#component-architecture-overview)
  - [Required Components](#required-components)
  - [Pluggable Components](#pluggable-components)
- [Deployment Overview](#deployment-overview)
  - [Phase 1: Infrastructure Foundation](#phase-1-infrastructure-foundation)
  - [Phase 2: Data Layer](#phase-2-data-layer)
  - [Phase 3: Application Layer](#phase-3-application-layer)
- [Pluggable Component Configuration](#pluggable-component-configuration)
  - [Database (PostgreSQL)](#database-postgresql)
  - [Gateway / Ingress](#gateway--ingress)
  - [Object Storage (S3-compatible)](#object-storage-s3-compatible)
  - [StorageClasses](#storageclasses)
  - [Secrets Management](#secrets-management)
- [Component Reference](#component-reference)

---

## Component Architecture Overview

AIWB is built with a modular architecture consisting of **required components** that are always needed and **pluggable components** that can be substituted with your own implementations.

### Required Components

These components are essential for AIWB operation and cannot be substituted:

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **AIWB Application** | Core workbench application | `aiwb` |
| **Keycloak** | OIDC authentication provider | `keycloak` |
| **AIM Engine** | Model catalog and serving management | `aim-system` |
| **KServe** | Model serving infrastructure | `kserve-system` |
| **AMD GPU Operator** | GPU detection, device plugin, and metrics | `amd-gpu-operator` |
| **cert-manager** | TLS certificate management | `cert-manager` |
| **Kyverno** | Policy engine for workspace PVC auto-creation | `kyverno` |
| **Gateway API CRDs** | Standard Kubernetes ingress abstraction | cluster-wide |

### Pluggable Components

These components can be replaced with your own implementations:

| Component | Reference Implementation | Pluggable? | Instructions |
|-----------|-------------------------|-----------------|--------------|
| **Database** | CloudNativePG PostgreSQL clusters | ✅ Yes - Any PostgreSQL 14+ | [db.md](pluggable/components/db.md) |
| **Gateway Controller** | kgateway (Gateway API) | ✅ Yes - Any Gateway API controller | [gateway.md](pluggable/components/gateway.md) |
| **Object Storage** | MinIO | ✅ Yes - Any S3-compatible storage | [s3.md](pluggable/components/s3.md) |
| **StorageClasses** | local-path (rancher.io) | ✅ Yes - Any CSI provisioner | [storage_classes.md](pluggable/components/storage_classes.md) |
| **Secrets Management** | Direct Kubernetes Secrets | ✅ Yes - ExternalSecrets, Vault, etc. | [secrets.md](pluggable/secrets/secrets.md) |
| **LoadBalancer** | MetalLB | ✅ Yes - Cloud LB, HAProxy, etc. | — |

---

## Deployment Overview

AIWB deployment consists of three phases that must be completed in order:

### Phase 1: Infrastructure Foundation

**Purpose:** Establish the foundational infrastructure layer

**Components to deploy:**

1. **cert-manager** (v1.18.2 or later)
   - Required for webhook TLS certificates
   - Must be fully ready before deploying other components
   - Namespace: `cert-manager`

2. **CloudNativePG Operator** (v0.26.0 or later) *[Pluggable]*
   - PostgreSQL database operator
   - Required only if using the reference PostgreSQL implementation
   - Namespace: `cnpg-system`

3. **Kyverno** (v3.5.1 or later)
   - Policy engine for automatic workspace PVC creation
   - Install base policies and storage policies
   - Namespace: `kyverno`

4. **Gateway API CRDs** (v1.3.0 or later)
   - Standard for ingress routing
   - Required even if using your own Gateway controller

5. **Gateway Controller** *[Pluggable]*
   - Reference: kgateway v2.1.0
   - Alternative: Any Gateway API-compliant controller (Envoy Gateway, Istio, Kong, etc.)
   - Namespace: `kgateway-system` (or your controller's namespace)

6. **LoadBalancer Implementation** *[Pluggable]*
   - Reference: MetalLB v0.15.2
   - Alternative: Cloud provider LoadBalancer, HAProxy LB, etc.
   - Namespace: `metallb-system` (or your LB's namespace)

7. **StorageClasses** *[Pluggable]*
   - Required classes: `multinode`, `mlstorage`
   - Reference: local-path provisioner (rancher.io)
   - Alternative: Any CSI driver (Longhorn, Ceph, EFS, etc.)

8. **OpenTelemetry Operator** (v0.93.1 or later)
   - Optional: Only if using AIWB observability features
   - Namespace: `opentelemetry-system`

9. **AMD GPU Operator** (v1.4.1)
   - Installs NFD (node detection), KMM (kernel module management), device plugin, and metrics exporter
   - Nodes with AMD GPUs are automatically labelled and `amd.com/gpu` resources are registered
   - Namespace: `amd-gpu-operator`
   - See [gpu_operator.md](components/gpu_operator.md) for optional configuration

### Phase 2: Data Layer

**Purpose:** Set up databases, object storage, and secrets

**Components to deploy:**

1. **Namespaces**
   - Create required namespaces: `aiwb`, `keycloak`, `workbench`, `minio-tenant-default`

2. **Secrets** *[Pluggable]*
   - Create all required secrets (see [Secrets Reference](#secrets-management))
   - Can use direct Kubernetes Secrets, ExternalSecrets, or Vault

3. **PostgreSQL Databases** *[Pluggable]*
   - **AIWB Database:** PostgreSQL 14+ with database `aiwb`
   - **Keycloak Database:** PostgreSQL 14+ with database `keycloak`
   - Reference: CloudNativePG clusters in `aiwb` and `keycloak` namespaces
   - Alternative: External managed PostgreSQL service

4. **Object Storage** *[Pluggable]*
   - Required buckets: `default-bucket`, `models`, `datasets`
   - Reference: MinIO operator + tenant in `minio-tenant-default`
   - Alternative: AWS S3, Azure Blob, GCS, or any S3-compatible service

5. **KServe** (v0.16.0 or later)
   - Model serving infrastructure
   - Deploy in RawDeployment mode (no Knative required)
   - Namespace: `kserve-system`

### Phase 3: Application Layer

**Purpose:** Deploy AIWB application and supporting services

**Components to deploy:**

1. **Keycloak** (v26.0.0 or later)
   - OIDC authentication provider
   - Must import the `airm` realm configuration
   - Namespace: `keycloak`
   - **Dependencies:** PostgreSQL database, cert-manager

2. **AIM Engine** (v0.2.2 or later)
   - Model catalog and lifecycle management
   - Deploys CRDs for AIMService, AIMClusterModel, etc.
   - Namespace: `aim-system`
   - **Dependencies:** KServe, Gateway

3. **AIM Model Catalog**
   - Deploy AIMClusterModelSource for model discovery
   - Default: v0.11.0 models from Docker Hub

4. **AIWB Application** (v1.0.3 or later)
   - Core workbench application (UI + API)
   - Namespace: `aiwb`
   - **Dependencies:** All components from Phase 1 & 2

---

## Pluggable Component Configuration

### Database (PostgreSQL)

**Reference Implementation:** CloudNativePG creates in-cluster PostgreSQL clusters for AIWB and Keycloak.

**To use your own PostgreSQL-compatible DB:**

See [db.md](pluggable/components/db.md) for configuration instructions.

---

### Gateway / Ingress

**Reference Implementation:** kgateway (Gateway API implementation) with MetalLB for LoadBalancer services.

**To use your own Gateway:**

See [gateway.md](pluggable/components/gateway.md) for configuration instructions.

---

### Object Storage (S3-compatible)

**Reference Implementation:** MinIO operator with a tenant providing three buckets (`default-bucket`, `models`, `datasets`).

**To use your own S3-compatible storage:**

See [s3.md](pluggable/components/s3.md) for configuration instructions.

---

### StorageClasses

**Reference Implementation:** `local-path` StorageClass using rancher.io provisioner (standard in K3s/Rancher Desktop). Note this is a sigle-node storage solution and not suitable for production.

**To use your own StorageClasses:**

See [storage_classes.md](pluggable/components/storage_classes.md) for configuration instructions.

---

### Secrets Management

**Reference Implementation:** Direct Kubernetes Secrets from YAML manifests.

**To use ExternalSecrets or another secrets provider:**

See [secrets.md](pluggable/secrets/secrets.md) for the complete list of required secrets and configuration instructions.

---

## Component Reference

Complete list of components and their versions:

### Core Infrastructure

| Component | Version | Namespace | Required | Alternative |
|-----------|---------|-----------|----------|-------------|
| cert-manager | v1.18.2 | `cert-manager` | ✅ Yes | None |
| Kyverno | v3.5.1 | `kyverno` | ✅ Yes | None |
| Gateway API CRDs | v1.3.0 | cluster-wide | ✅ Yes | None |
| CloudNativePG Operator | v0.26.0 | `cnpg-system` | ❌ No | External PostgreSQL |

### Networking

| Component | Version | Namespace | Required | Alternative |
|-----------|---------|-----------|----------|-------------|
| kgateway | v2.1.0 | `kgateway-system` | ❌ No | Any Gateway API controller |
| MetalLB | v0.15.2 | `metallb-system` | ❌ No | Cloud LoadBalancer, HAProxy |

### Data & Storage

| Component | Version | Namespace | Required | Alternative |
|-----------|---------|-----------|----------|-------------|
| MinIO Operator | v7.1.1 | `minio-operator` | ❌ No | AWS S3, Azure Blob, GCS |
| MinIO Tenant | v7.1.1 | `minio-tenant-default` | ❌ No | External S3 service |
| PostgreSQL (AIWB) | 14+ via CNPG | `aiwb` | ✅ Yes* | External PostgreSQL |
| PostgreSQL (Keycloak) | 14+ via CNPG | `keycloak` | ✅ Yes* | External PostgreSQL |

*Database is required but the implementation is pluggable

### Model Serving

| Component | Version | Namespace | Required | Alternative |
|-----------|---------|-----------|----------|-------------|
| KServe | v0.16.0 | `kserve-system` | ✅ Yes | None |
| AIM Engine | v0.2.2 | `aim-system` | ✅ Yes | None |

### Application

| Component | Version | Namespace | Required | Alternative |
|-----------|---------|-----------|----------|-------------|
| Keycloak | v26.0.0 | `keycloak` | ✅ Yes | None (OIDC support pending) |
| AIWB | v1.0.3 | `aiwb` | ✅ Yes | None |

### GPU

| Component | Version | Namespace | Required | Notes |
|-----------|---------|-----------|----------|-------|
| AMD GPU Operator | v1.4.1 | `amd-gpu-operator` | ✅ Yes (GPU nodes) | Includes NFD, KMM, device plugin, metrics exporter. See [gpu_operator.md](components/gpu_operator.md) |

### Optional

| Component | Version | Namespace | Required | Purpose |
|-----------|---------|-----------|----------|---------|
| OpenTelemetry Operator | v0.93.1 | `opentelemetry-system` | ❌ No | Observability instrumentation |
