#!/bin/bash

# Install all needed comonents regardless of what pluggable options are used

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

PLUGGABLE_DB=${PLUGGABLE_DB:-false}
PLUGGABLE_S3=${PLUGGABLE_S3:-false}

CNPG_INSTANCES=1
DOMAIN="localhost"
DEFAULT_STORAGE_CLASS_NAME="local-path"

# Download cluster-forge sources from GitHub
# User can force update with: FORCE_UPDATE=true ./install_base.sh
CLUSTER_FORGE_DIR="/tmp/cluster-forge"
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
  git clone --depth 1 --branch main --single-branch \
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
# METALLB CONFIGURATION
# ============================================================================

# Configure MetalLB with L2 mode and IP address pool
# Using 192.168.127.240-192.168.127.250 as the LoadBalancer IP range
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 192.168.127.240-192.168.127.250
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
  helm template kgateway-config ${SOURCES_DIR}/kgateway-config --namespace kgateway-system --set domain=${DOMAIN} | kubectl apply --server-side -f -
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
  | kubectl apply -f -
kubectl config set-context --current --namespace=default

# Wait for certificate to be ready
echo "⏳ Waiting for KServe webhook certificate to be ready..."
kubectl wait --for=condition=ready --timeout=60s certificate/serving-cert -n kserve-system

# Wait for KServe webhook to be ready
echo "⏳ Waiting for KServe controller to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/kserve-controller-manager -n kserve-system

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
echo "✅ KServe is ready"
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
  cluster-auth
  demo
  keycloak
  metallb-system
  aim-system
  kgateway-system
  workbench
  kaiwo-system
  minio-tenant-default
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

# Install Gateway API CRDs (standard)
kubectl apply -f ${SOURCES_DIR}/gateway-api/v1.3.0/experimental-install.yaml --server-side

# Install kgateway CRDs
helm template kgateway-crds ${SOURCES_DIR}/kgateway-crds/v2.0.4 | kubectl apply --server-side -f -

# FIX-ME: had to use --validate=ignore Kind=HTTPListenerPolicy): .spec.upgradeConfig: field not declared in schema
helm template kgateway-config ${SOURCES_DIR}/kgateway-config \
  --namespace kgateway-system \
  --set domain=placeholder.example.com \
  --set cnpg.instances=${CNPG_INSTANCES} \
  | kubectl apply --validate=ignore -f -
sleep 1

# Install AIWB PostgreSQL cluster
echo " 📦 Installing AIWB database cluster (${CNPG_INSTANCES} instance(s))..."
helm template aiwb-infra-cnpg ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0 \
  -f ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0/values.yaml \
  -f ${SOURCES_DIR}/eai-infra/aiwb-cnpg/values.yaml \
  --set instances=${CNPG_INSTANCES} \
  --set username=aiwb_user \
  --set storage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --set walStorage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --namespace aiwb | kubectl apply --server-side -f -

if [[ "${PLUGGABLE_DB}" != true ]]; then
  # Wait for AIWB database cluster to be ready
  echo "⏳ Waiting for AIWB database cluster to be ready..."
  sleep 2
  until kubectl get cluster -n aiwb -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
    echo "  Still waiting for AIWB PostgreSQL cluster..."
    sleep 5
  done
  echo "✅ AIWB infrastructure is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for AIWB database."
fi

# Install kgateway itself
kubectl create namespace kgateway-system --dry-run=client -o yaml | kubectl apply -f -
helm template kgateway ${SOURCES_DIR}/kgateway/v2.0.4 --namespace kgateway-system | kubectl apply --server-side -f -

# Wait for kgateway to be ready
kubectl wait --for=condition=available --timeout=120s deployment -l app.kubernetes.io/name=kgateway -n kgateway-system

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
rm -f ${TEMP_KC_DIR}/templates/es-*.yaml

# Fix placeholder in realm template (admin-client-id-value -> __AIRM_ADMIN_CLIENT_ID__)
sed -i 's/"admin-client-id-value"/"__AIRM_ADMIN_CLIENT_ID__"/g' ${TEMP_KC_DIR}/templates/keycloak-realm-templates-cm.yaml

# Fix zip command to handle symlinks and exclude system paths
sed -i 's|zip -r /opt/keycloak/providers/SilogenExtensionPackage.jar .|zip -r -y /opt/keycloak/providers/SilogenExtensionPackage.jar . -x "*/dev/*" "*/sys/*" "*/proc/*" 2>/dev/null \|\| true|' ${TEMP_KC_DIR}/templates/keycloak-deployment.yaml

# Fix KC_HOSTNAME to use configured domain
sed -i "s|value: https://kc.{{ .Values.domain }}|value: http://${DOMAIN}:8080|" ${TEMP_KC_DIR}/templates/keycloak-deployment.yaml

# Fix storageClass for CNPG data and WAL volumes
sed -i "s|storageClass: default|storageClass: ${DEFAULT_STORAGE_CLASS_NAME}|g" ${TEMP_KC_DIR}/templates/keycloak-cnpg.yaml

helm template keycloak ${TEMP_KC_DIR} \
  --set cnpg.instances=${CNPG_INSTANCES} \
  --set domain="$DOMAIN" \
  --set hostname="http://localhost:8080" \
  --set 'extraEnvVars[0].name=JAVA_OPTS_APPEND' \
  --set 'extraEnvVars[0].value=-XX:MaxRAMPercentage=65.0 -XX:InitialRAMPercentage=50.0 -XX:MaxMetaspaceSize=512m -XX:+ExitOnOutOfMemoryError -Djava.awt.headless=true' \
  --set storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
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

  # Install MinIO Tenant Config (excluding ExternalSecret manifests)
  echo "  📦 Installing MinIO Tenant configuration..."
  TEMP_MINIO_CONFIG_DIR=$(mktemp -d)
  cp -r ${SOURCES_DIR}/minio-tenant-config/* ${TEMP_MINIO_CONFIG_DIR}/
  rm -f ${TEMP_MINIO_CONFIG_DIR}/templates/*-es-*.yaml
  rm -f ${TEMP_MINIO_CONFIG_DIR}/templates/*-clustersecretstore.yaml
  helm template minio-tenant-config ${TEMP_MINIO_CONFIG_DIR} \
    --namespace minio-tenant-default \
    --set domain=${DOMAIN} \
    | kubectl apply --server-side -f -
  rm -rf ${TEMP_MINIO_CONFIG_DIR}
  echo "✅ MinIO configuration applied"
  echo ""
else
  echo "PLUGGABLE_S3=true => Skipping in-cluster MinIO Operator, Tenant and configuration."
  echo "See components/s3.md for instructions on connecting AIWB to your external MinIO."
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
echo "🚀 Installing AIWB application..."
helm template aiwb ${SOURCES_DIR}/aiwb/1.0.3 \
  --namespace aiwb \
  --set standAloneMode=true \
  --set appDomain="${DOMAIN}" \
  --set backend.clusterHost="http://${DOMAIN}:8000" \
  --set keycloak.url="http://${DOMAIN}:8080" \
  --set frontend.env.NEXTAUTH_URL="http://${DOMAIN}:8000" \
  --set frontend.env.KEYCLOAK_ISSUER="http://${DOMAIN}:8080/realms/airm" \
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
# echo "   kubectl get pods -n kueue-system"
echo "   kubectl get pods -n cnpg-system"
# echo "   kubectl get pods -n rabbitmq-system"
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
echo "ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md"
echo ""

if [[ "$PLUGGABLE_DB" == true ]]; then
  echo ""
  echo "PLUGGABLE_DB=true => Run scripts/db.sh to continue"
  echo "and connect AIWB to your external PostgreSQL. See components/db.md for instructions."
fi