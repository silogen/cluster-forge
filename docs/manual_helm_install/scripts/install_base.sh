#!/bin/bash

# Install all needed comonents regardless of what pluggable options are used

set -euo pipefail

# Require DOMAIN as first argument
if [ -z "${1:-}" ]; then
  echo "❌ Error: DOMAIN parameter is required"
  echo ""
  echo "Usage: $0 <DOMAIN>"
  echo ""
  echo "Examples:"
  echo "  $0 localhost              # For local testing"
  echo "  $0 example.com            # For production deployment"
  echo ""
  exit 1
fi

DOMAIN="$1"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

PLUGGABLE_DB=${PLUGGABLE_DB:-false}
PLUGGABLE_S3=${PLUGGABLE_S3:-false}

CNPG_INSTANCES=1
DEFAULT_STORAGE_CLASS_NAME="default"

# External MinIO config — used only when PLUGGABLE_S3=true to override the
# AIWB chart's MinIO endpoint. The in-cluster redirect Service that backs the
# in-cluster MinIO URL is set up separately by scripts/s3.sh.
MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
# Host port external MinIO publishes its S3 API on. Default 19000 matches the
# minio-byo container layout used in this dev workflow (container :9000 → host :19000).
MINIO_PORT="${MINIO_PORT:-19000}"
MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-192.168.127.240-192.168.127.250}"

# Derive protocol-aware URL bases from DOMAIN.
# For a real domain the gateway uses HTTPS with subdomain routing;
# for localhost it uses plain HTTP on fixed ports (overridden by post_install.sh).
if [ "${DOMAIN}" = "localhost" ]; then
  KC_HOSTNAME="http://localhost:8080"
  KC_URL="http://localhost:8080"
  AIWB_UI_URL="http://localhost:8000"
else
  KC_HOSTNAME="https://kc.${DOMAIN}"
  KC_URL="https://kc.${DOMAIN}"
  AIWB_UI_URL="https://aiwbui.${DOMAIN}"
fi

# Download cluster-forge sources from GitHub
# User can force update with: FORCE_UPDATE=true ./install_base.sh
CLUSTER_FORGE_DIR="/tmp/cluster-forge"
# Delete CLUSTER_FORGE_DIR manually if CLUSTER_FORGE_BRANCH changes
CLUSTER_FORGE_BRANCH="EAI-5784_byok_documentation"
SOURCES_DIR="${CLUSTER_FORGE_DIR}/sources"
FORCE_UPDATE=${FORCE_UPDATE:-false}

if [ -d "${CLUSTER_FORGE_DIR}" ]; then
  if [ "${FORCE_UPDATE}" = "true" ]; then
    echo "📥 Updating cluster-forge sources from GitHub..."
    (cd "${CLUSTER_FORGE_DIR}" && git pull)
  else
    echo "ℹ️  Using existing sources at ${SOURCES_DIR} (set FORCE_UPDATE=true to update)"
  fi
else
  echo "📥 Downloading cluster-forge sources from GitHub..."
  git clone --depth 1 --branch "${CLUSTER_FORGE_BRANCH}" --single-branch \
    https://github.com/silogen/cluster-forge.git "${CLUSTER_FORGE_DIR}"
  echo "✅ Sources downloaded to ${SOURCES_DIR}"
fi

# ============================================================================
# DATABASE OPERATOR (CloudNativePG)
# ============================================================================
# CNPG Cluster CRD is required for Keycloak and AIWB database templates.
# CNPG Cluster database resources will be removed by scripts/db.sh if selected.
# But scripts/install_base.sh needs the CRD to exist in the cluster first.
#
echo "📦 Installing CloudNativePG operator..."
kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f -
helm template cnpg-operator ${SOURCES_DIR}/cnpg-operator/0.26.0 --namespace cnpg-system | kubectl apply --server-side -f -

if [[ ${PLUGGABLE_DB} != true ]]; then
  echo "⏳ Waiting for CNPG operator to be ready..."
  kubectl wait --for=condition=available --timeout=120s deployment/cnpg-operator-cloudnative-pg -n cnpg-system
  echo "✅ CloudNativePG is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for CloudNativePG as it's going to be removed later."
fi

# ============================================================================
# KYVERNO (Policy Management)
# ============================================================================
# syncWave: -40
# Install Kyverno for policy management (required for storage policies)
echo "📦 Installing Kyverno..."
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
# Disable webhooksCleanup to prevent pre-delete hooks from running during helm template | kubectl apply
helm template kyverno ${SOURCES_DIR}/kyverno/3.5.1 --namespace kyverno --set webhooksCleanup.enabled=false | kubectl apply --server-side -f -

# Wait for Kyverno to be ready
echo "⏳ Waiting for Kyverno to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/kyverno-admission-controller -n kyverno
kubectl wait --for=condition=available --timeout=120s deployment/kyverno-background-controller -n kyverno
kubectl wait --for=condition=available --timeout=120s deployment/kyverno-cleanup-controller -n kyverno
kubectl wait --for=condition=available --timeout=120s deployment/kyverno-reports-controller -n kyverno
echo "✅ Kyverno is ready"
echo ""

# ============================================================================
# KYVERNO POLICIES
# ============================================================================
# syncWave: -30
# Install Kyverno policies for base security and storage management
echo "📦 Installing Kyverno base policies..."
helm template kyverno-policies-base ${SOURCES_DIR}/kyverno-policies/base --namespace kyverno | kubectl apply --server-side -f -

echo "📦 Installing Kyverno storage-local-path policies..."
helm template kyverno-policies-storage ${SOURCES_DIR}/kyverno-policies/storage-local-path --namespace kyverno | kubectl apply --server-side -f -

echo "✅ Kyverno policies installed"
echo ""

# ============================================================================
# STORAGE CLASSES
# ============================================================================
# Create multinode and mlstorage StorageClasses for workspace PVCs
echo "📦 Creating storage classes..."
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: multinode
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mlstorage
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
echo "✅ Storage classes created"
echo ""

# ============================================================================
# PROMETHEUS CRDs
# ============================================================================
# syncWave: -50
# Prometheus Operator CRDs required by monitoring components
echo "📦 Installing Prometheus Operator CRDs..."
kubectl create namespace prometheus-system --dry-run=client -o yaml | kubectl apply -f -
helm template prometheus-crds ${SOURCES_DIR}/prometheus-operator-crds/23.0.0 --namespace prometheus-system | kubectl apply --server-side -f -

echo "✅ Prometheus CRDs installed"
echo ""

# ============================================================================
# CERT-MANAGER
# ============================================================================
# syncWave: -30
# Required by OpenTelemetry Operator and KServe for webhook certificates
echo "📦 Installing cert-manager..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm template cert-manager ${SOURCES_DIR}/cert-manager/v1.18.2 --namespace cert-manager --set crds.enabled=true | kubectl apply --server-side -f -

# Wait for cert-manager to be ready (required for webhooks)
echo "⏳ Waiting for cert-manager deployments to be ready..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/cert-manager-webhook \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  -n cert-manager

# Wait for cert-manager webhook to have valid certificates (can take 10-30 seconds)
echo "⏳ Waiting for cert-manager webhook certificates to be ready..."
sleep 1
until kubectl get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; do
  echo "  Still waiting for webhook CA bundle..."
  sleep 5
done
echo "✅ cert-manager is ready"
echo ""

# ============================================================================
# OPENTELEMETRY OPERATOR & METALLB (parallel install)
# ============================================================================
# syncWave: -25 (OpenTelemetry), 10 (MetalLB)
# These components are independent and can be installed in parallel

echo "📦 Installing OpenTelemetry Operator..."
kubectl create namespace opentelemetry-system --dry-run=client -o yaml | kubectl apply -f -
helm template opentelemetry-operator ${SOURCES_DIR}/opentelemetry-operator/0.93.1 --namespace opentelemetry-system --include-crds | kubectl apply --server-side -f -

echo "📦 Installing MetalLB..."
kubectl apply -f ${SOURCES_DIR}/metallb/v0.15.2/metallb-native.yaml --server-side

# Wait for both (separately to avoid race conditions)
echo "⏳ Waiting for MetalLB to be ready..."
until kubectl get deployment controller -n metallb-system >/dev/null 2>&1; do
  sleep 1
done
kubectl wait --for=condition=available --timeout=120s deployment/controller -n metallb-system

echo "⏳ Waiting for OpenTelemetry Operator to be ready..."
until kubectl get deployment opentelemetry-operator -n opentelemetry-system >/dev/null 2>&1; do
  sleep 1
done
kubectl wait --for=condition=available --timeout=120s deployment/opentelemetry-operator -n opentelemetry-system

echo "✅ OpenTelemetry Operator and MetalLB are ready"
echo ""

# ============================================================================
# OTEL LGTM STACK (Observability)
# ============================================================================
# syncWave: -20
# Complete observability stack: Prometheus, Grafana, Loki, Tempo, Mimir
# Depends on: OpenTelemetry Operator, Prometheus CRDs
echo "📦 Installing OTEL LGTM Stack (Prometheus, Grafana, Loki, Tempo)..."
kubectl create namespace otel-lgtm-stack --dry-run=client -o yaml | kubectl apply -f -

# Use values from cluster-forge with medium-sized resource overrides
helm template otel-lgtm-stack ${SOURCES_DIR}/otel-lgtm-stack/v1.0.7 \
  --namespace otel-lgtm-stack \
  --set cluster.name="${DOMAIN}" \
  --set collectors.resources.metrics.requests.cpu=500m \
  --set collectors.resources.metrics.requests.memory=1Gi \
  --set collectors.resources.metrics.limits.memory=4Gi \
  --set collectors.resources.logs.requests.cpu=250m \
  --set collectors.resources.logs.requests.memory=256Mi \
  --set collectors.resources.logs.limits.cpu=1 \
  --set collectors.resources.logs.limits.memory=1Gi \
  --set dashboards.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --set nodeExporter.enabled=true \
  --set lgtm.resources.requests.cpu=1 \
  --set lgtm.resources.requests.memory=2Gi \
  --set lgtm.resources.limits.memory=8Gi \
  --set lgtm.storage.grafana=10Gi \
  --set lgtm.storage.loki=50Gi \
  --set lgtm.storage.mimir=50Gi \
  --set lgtm.storage.tempo=50Gi \
  --set lgtm.storage.extra=50Gi \
  | kubectl apply --server-side -f -

# Wait for main LGTM components
echo "⏳ Waiting for LGTM stack to be ready..."
sleep 5
kubectl wait --for=condition=available --timeout=180s deployment -l app.kubernetes.io/name=lgtm -n otel-lgtm-stack 2>/dev/null || echo "⚠️  LGTM deployment check completed"

echo "✅ OTEL LGTM Stack is ready"
echo ""

# ============================================================================
# KEDA (Kubernetes Event-Driven Autoscaling)
# ============================================================================
# syncWave: -10
# Required by KServe for autoscaling inference workloads
# Depends on: OpenTelemetry Operator (for metrics), cert-manager (for webhooks)
echo "📦 Installing KEDA..."
kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f -
helm template keda ${SOURCES_DIR}/keda/2.18.1 --namespace keda | kubectl apply --server-side -f -

# Wait for KEDA operator to be ready
echo "⏳ Waiting for KEDA operator to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/keda-operator -n keda

# Wait for KEDA metrics server to be ready
echo "⏳ Waiting for KEDA metrics server to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/keda-operator-metrics-apiserver -n keda

# Wait for KEDA admission webhooks to be ready
echo "⏳ Waiting for KEDA admission webhooks to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/keda-admission-webhooks -n keda

echo "✅ KEDA is ready"
echo ""

# ============================================================================
# KEDIFY OTEL SCALER
# ============================================================================
# syncWave: -5
# Provides OpenTelemetry metrics integration for KEDA
# Depends on: KEDA
echo "📦 Installing Kedify OTEL Scaler..."
helm template kedify-otel ${SOURCES_DIR}/kedify-otel/v0.0.6 \
  --namespace keda \
  --set validatingAdmissionPolicy.enabled=false \
  | kubectl apply --server-side -f -

# Wait for Kedify OTEL scaler to be ready
echo "⏳ Waiting for Kedify OTEL scaler to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/keda-otel-scaler -n keda 2>/dev/null || echo "⚠️  Kedify OTEL scaler deployment check completed"

echo "✅ Kedify OTEL Scaler is ready"
echo ""

# ============================================================================
# METALLB CONFIGURATION
# ============================================================================

# Configure MetalLB with L2 mode and IP address pool.
# Skip creating the IPAddressPool if one already covers METALLB_IP_RANGE
# (e.g. a cloud provider or previous install already configured MetalLB).
if KUBECONFIG="${KUBECONFIG:-}" kubectl get ipaddresspools -n metallb-system -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null \
    | tr ' ' '\n' | grep -qF "${METALLB_IP_RANGE%%-*}"; then
  echo "ℹ️  MetalLB IPAddressPool covering ${METALLB_IP_RANGE} already exists — skipping pool creation"
else
  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
EOF
fi

echo "✅ MetalLB installed and configured"
echo ""

# ============================================================================
# GATEWAY API & KGATEWAY
# ============================================================================
# syncWave: -50 (gateway-api), -30 (kgateway-crds), -20 (kgateway)
# Required for AIWB HTTPRoute routing
echo "📦 Installing Gateway API..."
kubectl apply -f ${SOURCES_DIR}/gateway-api/v1.3.0/experimental-install.yaml --server-side

# Install kgateway as the Gateway API implementation
kubectl create namespace kgateway-system --dry-run=client -o yaml | kubectl apply -f -
helm template kgateway-crds ${SOURCES_DIR}/kgateway-crds/v2.1.0-main --namespace kgateway-system | kubectl apply --server-side -f -
helm template kgateway ${SOURCES_DIR}/kgateway/v2.1.0-main --namespace kgateway-system --set service.type=LoadBalancer | kubectl apply --server-side -f -

# Patch: kgateway v2.1.0-main ClusterRole is missing tokenreviews, which the xDS server
# requires to validate JWT tokens from Envoy proxy. Without it, Envoy cannot connect to
# the xDS control plane and the gateway serves no routes.
kubectl patch clusterrole kgateway-kgateway-system --type=json -p='[
  {
    "op": "add",
    "path": "/rules/-",
    "value": {
      "apiGroups": ["authentication.k8s.io"],
      "resources": ["tokenreviews"],
      "verbs": ["create"]
    }
  }
]'

# Wait for kgateway to be ready
echo "⏳ Waiting for kgateway to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/kgateway -n kgateway-system

# Create Gateway resource and policies for AIWB routing
echo "📦 Creating AIWB Gateway resource and policies..."
if [ "${DOMAIN}" = "localhost" ]; then
  # For localhost: use HTTP on port 8080 without TLS
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: https
  namespace: kgateway-system
spec:
  gatewayClassName: kgateway
  listeners:
  - name: http
    protocol: HTTP
    port: 8080
    allowedRoutes:
      namespaces:
        from: All
EOF
else
  # For production: use kgateway-config templates with HTTPS/TLS
  # --validate=ignore required: HTTPListenerPolicy.spec.upgradeConfig not yet in the CRD schema
  helm template kgateway-config ${SOURCES_DIR}/kgateway-config \
    --namespace kgateway-system \
    --set domain=${DOMAIN} \
    --set cnpg.instances=${CNPG_INSTANCES} \
    | kubectl apply --validate=ignore -f -
fi

# Apply WebSocket policy (needed for workbench terminals and logs streaming)
kubectl apply -f ${SOURCES_DIR}/kgateway-config/templates/HTTPListenerPolicy_websocket.yaml

echo "✅ Gateway API and kgateway installed"
echo ""

# ============================================================================
# KSERVE
# ============================================================================
# syncWave: -30 (crds), 0 (operator)
# Required for model serving integration with AIM-Engine
echo "📦 Installing KServe CRDs..."
kubectl create namespace kserve-system --dry-run=client -o yaml | kubectl apply -f -
helm template kserve-crds ${SOURCES_DIR}/kserve-crds/v0.16.0 --namespace kserve-system | kubectl apply --server-side -f -

echo "📦 Installing KServe operator..."
# IMPORTANT: cert-manager Certificate resources don't work well with --server-side
# Apply them separately with regular kubectl apply
# Set deploymentMode to RawDeployment (default is Knative, which requires Knative Serving)
kubectl config set-context --current --namespace=kserve-system
helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
  --namespace kserve-system \
  --set kserve.controller.deploymentMode=RawDeployment \
  | kubectl apply -f - 2>&1 | grep -v "Error from server" || true

# Wait for certificate to be ready
echo "⏳ Waiting for KServe webhook certificate to be ready..."
kubectl wait --for=condition=ready --timeout=60s certificate/serving-cert -n kserve-system

# Wait for KServe webhook to be ready
echo "⏳ Waiting for KServe controller to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/kserve-controller-manager -n kserve-system

echo "Applying KServe again to ensure all resources are created (some may fail on first apply due to webhook not being ready)..."
helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
  --namespace kserve-system \
  --set kserve.controller.deploymentMode=RawDeployment \
  | kubectl apply -f -
kubectl config set-context --current --namespace=default

# Wait for webhook endpoints to be available (can take 10-30 seconds after deployment is ready)
echo "⏳ Waiting for KServe webhook endpoints to be ready..."
sleep 10
until kubectl get endpoints kserve-webhook-server-service -n kserve-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
  echo "  Still waiting for webhook endpoints..."
  sleep 5
done

# Wait for webhook CA bundle to be injected
until kubectl get validatingwebhookconfigurations clusterservingruntime.serving.kserve.io -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; do
  echo "  Still waiting for webhook CA bundle..."
  sleep 5
done

# Now re-apply to ensure any resources that failed due to webhook are created
echo "📦 Re-applying KServe to ensure all resources are created..."
helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
  --namespace kserve-system \
  --set kserve.controller.deploymentMode=RawDeployment \
  | kubectl apply -f - 2>&1 | grep -v "unchanged" | head -20

# Patch: kserve default cpuLimit of "1" causes InferenceService validation failures when
# the AIM engine profile sets requests.cpu > 1 (e.g. 4 for throughput-optimised templates).
# Setting cpuLimit to "" removes the default cap; cpuRequest remains as a scheduling hint.
kubectl patch configmap inferenceservice-config -n kserve-system --type=merge -p \
  '{"data":{"inferenceService":"{\"resource\":{\"cpuLimit\":\"\",\"cpuRequest\":\"1\",\"memoryLimit\":\"2Gi\",\"memoryRequest\":\"2Gi\"}}"}}'

echo "✅ KServe is ready"
echo ""

# ============================================================================
# AMD GPU OPERATOR
# ============================================================================
# syncWave: -10
# Installs Node Feature Discovery (NFD), Kernel Module Management (KMM),
# and the AMD GPU device plugin/metrics exporter.
# Nodes with AMD GPUs are automatically labelled via NFD and the device plugin
# advertises amd.com/gpu resources so workloads can request them.
echo "📦 Installing AMD GPU Operator..."
kubectl create namespace amd-gpu-operator --dry-run=client -o yaml | kubectl apply -f -

# Apply CRDs directly first and wait for them to be established.
# The GPU operator chart's subchart CRDs (NFD, KMM) must exist in the API server
# before any pods start, otherwise they crash-loop on missing nodefeatures/nodefeaturegroups.
# We use kubectl apply rather than helm's CRD handling because helm install with CRDs
# is not idempotent across re-runs without a pre-existing release.
kubectl apply --server-side -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/crds/
kubectl apply --server-side -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/charts/node-feature-discovery/crds/
kubectl apply --server-side -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/charts/kmm/crds/

echo "⏳ Waiting for AMD GPU Operator CRDs to be established..."
kubectl wait --for=condition=established --timeout=60s \
  crd/nodefeatures.nfd.k8s-sigs.io \
  crd/deviceconfigs.amd.com \
  crd/modules.kmm.sigs.x-k8s.io

# Use helm upgrade --install (not helm template | kubectl apply) so that all resources
# get the correct release namespace injected. The GPU operator chart omits explicit
# namespace on several cluster-scoped resources and relies on Helm's injection.
helm upgrade --install amd-gpu-operator ${SOURCES_DIR}/amd-gpu-operator/v1.4.1 \
  --namespace amd-gpu-operator \
  --set crds.defaultCR.install=true \
  --skip-crds \
  --kubeconfig "${KUBECONFIG:-}"

echo "⏳ Waiting for AMD GPU Operator controller to be ready..."
kubectl wait --for=condition=available --timeout=180s \
  deployment/amd-gpu-operator-gpu-operator-charts-controller-manager -n amd-gpu-operator
echo "✅ AMD GPU Operator is ready"
echo ""

# ============================================================================
# AIM ENGINE (Controller + CRDs)
# ============================================================================
# Required by AIWB for AIMService resources and model catalog

# Stage 1: Install CRDs
echo "📦 Installing AIM Engine CRDs..."
kubectl create namespace aim-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ${SOURCES_DIR}/aim-engine-crds/0.2.2/crds.yaml --namespace aim-system --recursive

# Stage 2: Install AIM Engine operator
echo "📦 Installing AIM Engine operator..."
GATEWAY_NAME="https"
GATEWAY_NAMESPACE="kgateway-system"

helm template aim-engine ${SOURCES_DIR}/aim-engine/0.2.2 \
  --namespace aim-system \
  --set clusterRuntimeConfig.enable=true \
  --set clusterRuntimeConfig.spec.routing.enabled=true \
  --set clusterRuntimeConfig.spec.routing.gatewayRef.name=${GATEWAY_NAME} \
  --set clusterRuntimeConfig.spec.routing.gatewayRef.namespace=${GATEWAY_NAMESPACE} \
  | kubectl apply --server-side -f -

# Stage 3: Install AIMClusterModelSource for model auto-discovery
echo "📦 Installing AIM Cluster Model Source (v0.11.0)..."
kubectl apply -f ${SOURCES_DIR}/aim-cluster-model-source/aim-models-0.9.0.yaml
kubectl apply -f ${SOURCES_DIR}/aim-cluster-model-source/aim-models-0.10.0.yaml
kubectl apply -f ${SOURCES_DIR}/aim-cluster-model-source/aim-models-0.11.0.yaml

echo "✅ AIM Engine installed"
echo ""

# ============================================================================
# AIWB INFRASTRUCTURE (Database and Secrets)
# ============================================================================

echo "📦 Installing AIWB infrastructure..."
kubectl create namespace aiwb --dry-run=client -o yaml | kubectl apply -f -

# Create namespaces needed for secrets which don't exist yet
NAMESPACES=(
  airm
  demo
  keycloak
  metallb-system
  aim-system
  kgateway-system
  workbench
  kaiwo-system
  minio-tenant-default
  cluster-auth
)

for ns in "${NAMESPACES[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Install AIWB secrets from local file
echo "  📦 Installing AIWB secrets..."
# Apply AIWB standalone secrets (all placeholder credentials)
kubectl apply -f "${SCRIPT_DIR}/../secrets/secrets-aiwb.yaml"

# Apply secrets with hardcoded values (overrides secrets-aiwb.yaml where needed)
kubectl apply -f "${SCRIPT_DIR}/../secrets/secrets-override-hardcoded.yaml"

# Apply AIWB standalone mode specific secrets
kubectl apply -f "${SCRIPT_DIR}/../secrets/secrets-aiwb-standalone.yaml"
echo "  ✅ Secrets applied"

# ============================================================================
# CLUSTER-AUTH SHIM (standalone mode only)
# ============================================================================
# cluster-auth normally requires OpenBao for API key group persistence.
# This in-memory shim implements the cluster-auth REST API so that aiwb-api
# can create API key groups for model deployments without OpenBao.
# State is lost on pod restart; suitable for standalone/dev installs only.
echo "📦 Installing cluster-auth shim..."

kubectl create configmap cluster-auth-shim \
  -n cluster-auth \
  --from-file=shim.py="${SCRIPT_DIR}/cluster-auth-shim.py" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-auth
  template:
    metadata:
      labels:
        app: cluster-auth
    spec:
      containers:
      - name: shim
        image: python:3.11-slim
        command: ["python3", "/shim/shim.py"]
        ports:
        - containerPort: 8081
        volumeMounts:
        - name: shim
          mountPath: /shim
      volumes:
      - name: shim
        configMap:
          name: cluster-auth-shim
---
apiVersion: v1
kind: Service
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  selector:
    app: cluster-auth
  ports:
  - name: rest-api
    port: 8081
    targetPort: 8081
  type: ClusterIP
EOF

# Admin token secret consumed by aiwb-api as CLUSTER_AUTH_ADMIN_TOKEN
kubectl create secret generic cluster-auth-admin-token \
  -n aiwb \
  --from-literal=value=standalone-shim-token \
  --dry-run=client -o yaml | kubectl apply -f -

echo "⏳ Waiting for cluster-auth shim to be ready..."
kubectl wait --for=condition=available --timeout=60s deployment/cluster-auth -n cluster-auth
echo "✅ cluster-auth shim is ready"
echo ""

# ============================================================================
# AIWB DATABASE CLUSTER
# ============================================================================
echo "📦 Installing AIWB database cluster (${CNPG_INSTANCES} instance(s))..."
helm template aiwb-infra-cnpg ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0 \
  -f ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0/values.yaml \
  --set instances=${CNPG_INSTANCES} \
  --set username=aiwb_user \
  --set storage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --set walStorage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --namespace aiwb | kubectl apply --server-side -f -

if [[ "${PLUGGABLE_DB}" != true ]]; then
  echo "⏳ Waiting for AIWB database cluster to be ready..."
  sleep 2
  until kubectl get cluster -n aiwb -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
    echo "  Still waiting for AIWB PostgreSQL cluster..."
    sleep 5
  done
  echo "✅ AIWB database is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for AIWB database."
fi

# ============================================================================
# KEYCLOAK (Identity and Access Management) - Start Early
# ============================================================================
# Start Keycloak installation now so it runs in parallel with MinIO
# We'll wait for it to be ready later, just before AIWB needs it
echo "📦 Starting Keycloak installation (will complete in background)..."

# Install Keycloak with embedded PostgreSQL cluster (excluding ExternalSecret manifests)
# Create temporary directory and copy all files except es-* (ExternalSecret) files
echo "  📦 Installing Keycloak with PostgreSQL cluster (${CNPG_INSTANCES} instance(s))..."
TEMP_KC_DIR=$(mktemp -d)
cp -r ${SOURCES_DIR}/keycloak-old/* ${TEMP_KC_DIR}/

# Fix placeholder in realm template (admin-client-id-value -> __AIRM_ADMIN_CLIENT_ID__)
sed -i 's/"admin-client-id-value"/"__AIRM_ADMIN_CLIENT_ID__"/g' ${TEMP_KC_DIR}/templates/keycloak-realm-templates-cm.yaml

# Fix zip command to handle symlinks and exclude system paths
sed -i 's|zip -r /opt/keycloak/providers/SilogenExtensionPackage.jar .|zip -r -y /opt/keycloak/providers/SilogenExtensionPackage.jar . -x "*/dev/*" "*/sys/*" "*/proc/*" 2>/dev/null \|\| true|' ${TEMP_KC_DIR}/templates/keycloak-deployment.yaml

# Fix KC_HOSTNAME to use configured domain
sed -i "s|value: https://kc.{{ .Values.domain }}|value: ${KC_HOSTNAME}|" ${TEMP_KC_DIR}/templates/keycloak-deployment.yaml

helm template keycloak ${TEMP_KC_DIR} \
  --set externalSecrets.enabled=false \
  --set cnpg.instances=${CNPG_INSTANCES} \
  --set cnpg.storage.storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
  --set domain="$DOMAIN" \
  --set hostname="${KC_HOSTNAME}" \
  --set 'extraEnvVars[0].name=JAVA_OPTS_APPEND' \
  --set 'extraEnvVars[0].value=-XX:MaxRAMPercentage=65.0 -XX:InitialRAMPercentage=50.0 -XX:MaxMetaspaceSize=512m -XX:+ExitOnOutOfMemoryError -Djava.awt.headless=true' \
  --namespace keycloak | kubectl apply --server-side -f -
rm -rf ${TEMP_KC_DIR}

echo "  ✅ Keycloak installation triggered (PostgreSQL + deployment starting)"
echo ""

# ============================================================================
# MINIO (Object Storage)
# ============================================================================
if [[ "${PLUGGABLE_S3}" != true ]]; then
  echo "📦 Installing MinIO..."

  # Install MinIO Operator
  echo "  📦 Installing MinIO Operator..."
  kubectl create namespace minio-operator --dry-run=client -o yaml | kubectl apply -f -
  helm template minio-operator ${SOURCES_DIR}/minio-operator/7.1.1 \
    --namespace minio-operator \
    --set operator.replicaCount=1 \
    | kubectl apply --server-side -f -

  # Wait for MinIO operator to be ready
  echo "⏳ Waiting for MinIO operator to be ready..."
  kubectl wait --for=condition=available --timeout=120s deployment -l app.kubernetes.io/name=operator -n minio-operator 2>/dev/null || echo "⚠️  MinIO operator deployment check completed"
  echo "✅ MinIO Operator is ready"
  echo ""

  # Install MinIO Tenant
  echo "  📦 Installing MinIO Tenant (default-bucket)..."
  kubectl create namespace minio-tenant-default --dry-run=client -o yaml | kubectl apply -f -

  # Create tenant configuration secret
  kubectl create secret generic default-minio-tenant-env-configuration \
    --from-literal=config.env="export MINIO_ROOT_USER=placeholder
  export MINIO_ROOT_PASSWORD=placeholder" \
    -n minio-tenant-default \
    --dry-run=client -o yaml | kubectl apply -f -

  helm template minio-tenant ${SOURCES_DIR}/minio-tenant/7.1.1 \
    --namespace minio-tenant-default \
    --set tenant.name=default-minio-tenant \
    --set tenant.pools[0].name=pool-0 \
    --set tenant.pools[0].servers=1 \
    --set tenant.pools[0].volumesPerServer=1 \
    --set tenant.pools[0].size=10Gi \
    --set tenant.pools[0].storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
    --set tenant.buckets[0].name=default-bucket \
    --set tenant.buckets[0].objectLock=true \
    --set tenant.buckets[1].name=models \
    --set tenant.buckets[1].objectLock=true \
    --set tenant.buckets[2].name=datasets \
    --set tenant.buckets[2].objectLock=false \
    --set tenant.configSecret.existingSecret=true \
    --set tenant.configSecret.name=default-minio-tenant-env-configuration \
    --set tenant.certificate.requestAutoCert=false \
    | kubectl apply --server-side -n minio-tenant-default -f -

  # Wait for MinIO tenant to be ready
  echo "⏳ Waiting for MinIO tenant to be ready..."
  sleep 2
  kubectl wait --for=condition=ready --timeout=300s pod -l app=minio -n minio-tenant-default 2>/dev/null || echo "⚠️  MinIO tenant check completed"
  echo "✅ MinIO Tenant is ready"
  echo ""

  echo "  📦 Installing MinIO Tenant configuration..."
  helm template minio-tenant-config ${SOURCES_DIR}/minio-tenant-config \
    --namespace minio-tenant-default \
    --set externalSecrets.enabled=false \
    --set domain=${DOMAIN} \
    | kubectl apply --server-side -f -
  echo "✅ MinIO configuration applied"
  echo ""
else
  echo "PLUGGABLE_S3=true => Skipping in-cluster MinIO Operator, Tenant and configuration."
  echo "Run scripts/s3.sh after this script completes — it creates the in-cluster"
  echo "redirect Service that forwards the in-cluster MinIO URL to ${MINIO_HOST}:${MINIO_PORT}"
  echo "and patches the AIWB credentials."
  echo ""
fi

# ============================================================================
# WAIT FOR KEYCLOAK - Ready Check
# ============================================================================
# Keycloak was started earlier (in parallel with MinIO)
# Now wait for it to be ready before installing AIWB
if [[ "${PLUGGABLE_DB}" != true ]]; then
  echo "⏳ Waiting for Keycloak database cluster to be ready..."
  sleep 5
  until kubectl get cluster keycloak-cnpg -n keycloak -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
    echo "  Still waiting for PostgreSQL cluster..."
    sleep 5
  done
  echo "✅ Keycloak database is ready"

  # Wait for Keycloak deployment to be ready
  echo "⏳ Waiting for Keycloak to be ready..."
  kubectl wait --for=condition=available --timeout=300s deployment/keycloak -n keycloak || { echo "⚠️  Keycloak deployment check timed out, exiting..."; exit 1; }
  echo "✅ Keycloak is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for Keycloak or its database to be ready since it's going to be patched later."
fi


# ============================================================================
# AIWB APPLICATION
# ============================================================================
# When PLUGGABLE_S3=true, point AIWB directly at the external MinIO endpoint
# rather than relying on the redirect Service. Keeps aiwb-api one indirection
# closer to the truth.
AIWB_PLUGGABLE_S3_ARGS=""
if [[ "${PLUGGABLE_S3}" == true ]]; then
  AIWB_PLUGGABLE_S3_ARGS="--set minio.url=http://${MINIO_HOST}:${MINIO_PORT} --set minio.bucket=${MINIO_BUCKET}"
fi

echo "🚀 Installing AIWB application..."
helm template aiwb ${SOURCES_DIR}/aiwb/1.0.31 \
  --namespace aiwb \
  --set standAloneMode=true \
  --set appDomain="${DOMAIN}" \
  --set backend.clusterHost="${AIWB_UI_URL}" \
  --set keycloak.url="${KC_URL}" \
  --set frontend.env.NEXTAUTH_URL="${AIWB_UI_URL}" \
  --set frontend.env.KEYCLOAK_ISSUER="${KC_URL}/realms/airm" \
  ${AIWB_PLUGGABLE_S3_ARGS} \
  | kubectl apply --server-side -f -

# Wait for AIWB to be ready
echo "⏳ Waiting for AIWB to be ready..."
# AIWB may have multiple deployments, wait for the main one
kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=aiwb -n aiwb 2>/dev/null || echo "⚠️  AIWB deployment check completed with warnings"
echo "✅ AIWB application is ready"
echo ""

echo "💡 Verification commands:"
echo "   kubectl get pods -n keycloak"
echo "   kubectl get pods -n aiwb"
echo "   kubectl get pods -n kaiwo-system"
echo "   kubectl get pods -n keda"
echo "   kubectl get pods -n otel-lgtm-stack"
# echo "   kubectl get pods -n kueue-system"
echo "   kubectl get pods -n cnpg-system"
# echo "   kubectl get pods -n rabbitmq-system"
echo "   kubectl get pods -n amd-gpu-operator"
echo "   kubectl get cluster --all-namespaces"
echo ""
if [ "$DOMAIN" = "localhost" ]; then
  GATEWAY_IP=$(kubectl get gateway https -n kgateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")
  echo "💡 Local Access via Gateway LoadBalancer:"
  echo "   Gateway IP: ${GATEWAY_IP}:8080"
  echo ""
  echo "   Access services using Host headers:"
  echo "   # AIWB UI"
  echo "   curl -H 'Host: aiwbui.localhost' http://${GATEWAY_IP}:8080"
  echo ""
  echo "   # AIWB API"
  echo "   curl -H 'Host: aiwbapi.localhost' http://${GATEWAY_IP}:8080/health"
  echo ""
  echo "   # Keycloak"
  echo "   curl -H 'Host: kc.localhost' http://${GATEWAY_IP}:8080/health"
  echo ""
  echo "   Add to /etc/hosts for browser access:"
  echo "   ${GATEWAY_IP} aiwbui.localhost aiwbapi.localhost kc.localhost"
  echo ""
  echo "💡 Alternative: Port Forward (if Gateway IP not accessible):"
  echo "   kubectl port-forward -n aiwb svc/aiwb-ui 8000:8000"
  echo "   kubectl port-forward -n aiwb svc/aiwb-api 8001:8080"
  echo "   kubectl port-forward -n keycloak svc/keycloak 8080:8080"
  echo "   kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000  # Grafana"
  echo "   kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090  # Prometheus"
else
  echo "💡 Access:"
  GATEWAY_IP=$(kubectl get gateway https -n kgateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "${DOMAIN}")
  echo "   Gateway IP: ${GATEWAY_IP}:8080"
  echo "   AIWB UI: https://aiwbui.${DOMAIN}"
  echo "   AIWB API: https://aiwbapi.${DOMAIN}"
  echo "   Keycloak: https://kc.${DOMAIN}"
  echo ""
  echo "   Ensure DNS points aiwbui.${DOMAIN}, aiwbapi.${DOMAIN}, and kc.${DOMAIN} to ${GATEWAY_IP}"
fi
echo ""
echo "💡 Keycloak Admin Credentials:"
echo "   Username: silogen-admin"
echo "   Password: placeholder"
echo "   Admin Console: http://${DOMAIN}:8080/admin"
echo ""
echo "💡 AIWB User Login:"
echo "   Username: devuser@${DOMAIN}"
echo "   Password: placeholder"
echo ""
echo "📊 Observability (Grafana, Prometheus, Loki, Tempo):"
echo "   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000"
echo "   Access Grafana at: http://localhost:3000"
echo "   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090"
echo "   Access Prometheus at: http://localhost:9090"
echo ""
echo "ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md"
echo ""

if [[ "$PLUGGABLE_DB" == true ]]; then
  echo ""
  echo "PLUGGABLE_DB=true => Run scripts/db.sh to continue"
  echo "and connect AIWB to your external PostgreSQL. See components/db.md for instructions."
fi
