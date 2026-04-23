#!/bin/bash

# BYO S3 Override Script — Proof-of-Concept
# Removes the in-cluster MinIO Tenant and patches Kubernetes resources so that
# AIWB connects to an external MinIO-compatible object storage instead.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-examplepass}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-examplepass}"
MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
KUBE_CONTEXT="${KUBE_CONTEXT:-rancher-desktop}"

AIWB_NAMESPACE="aiwb"
WORKBENCH_NAMESPACE="workbench"
MINIO_NAMESPACE="minio-tenant-default"
MINIO_TENANT_NAME="default-minio-tenant"

# ============================================================================
# Helpers
# ============================================================================

log_info()    { echo "📦 $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error()   { echo "❌ $1" >&2; }

encode_base64() { echo -n "$1" | base64 -w 0; }

check_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
  fi
}

check_context() {
  local current
  current=$(kubectl config current-context 2>/dev/null || echo "")
  if [ "${current}" != "${KUBE_CONTEXT}" ]; then
    log_warning "Current context is '${current}', expected '${KUBE_CONTEXT}'"
    log_info "Switching to context '${KUBE_CONTEXT}'..."
    kubectl config use-context "${KUBE_CONTEXT}" || {
      log_error "Failed to switch to context '${KUBE_CONTEXT}'"
      exit 1
    }
  fi
  log_success "Using kubectl context: ${KUBE_CONTEXT}"
}

# ============================================================================
# Pre-flight
# ============================================================================

echo ""
echo "=========================================================================="
echo "  BYO S3 Override — External MinIO Configuration"
echo "=========================================================================="
echo "  External MinIO: http://${MINIO_HOST}:${MINIO_PORT}"
echo "  Bucket:         ${MINIO_BUCKET}"
echo "=========================================================================="
echo ""

check_kubectl
check_context

# ============================================================================
# WARNING: Destructive step — delete in-cluster MinIO Tenant
# ============================================================================

echo ""
echo "=========================================================================="
echo "⚠️  WARNING: DESTRUCTIVE OPERATION — DATA LOSS"
echo "=========================================================================="
echo "  This script will DELETE the in-cluster MinIO Tenant '${MINIO_TENANT_NAME}'"
echo "  from namespace '${MINIO_NAMESPACE}' and ALL DATA stored in it."
echo ""
echo "  ALL object storage data (datasets, models, uploads) will be permanently"
echo "  lost. This action CANNOT be undone."
echo ""
echo "  Before continuing, ensure:"
echo "    1. All data in the in-cluster MinIO has been backed up or is not needed"
echo "    2. External MinIO is running at ${MINIO_HOST}:${MINIO_PORT}"
echo "    3. External MinIO has the required buckets: default-bucket, models, datasets"
echo "    4. External MinIO credentials are: ${MINIO_ACCESS_KEY} / ${MINIO_SECRET_KEY}"
echo "=========================================================================="
echo ""
read -r -p "Type 'yes' to confirm data loss and proceed: " confirm
if [[ "${confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi
echo ""

# ============================================================================
# Remove minio-tenant-config CronJob and Jobs first
# (prevents new Error pods from spawning after the Tenant is deleted)
# ============================================================================

log_info "Deleting mc-user-create-cronjob and all associated Jobs..."
kubectl delete cronjob mc-user-create-cronjob \
  -n "${MINIO_NAMESPACE}" \
  --ignore-not-found \
  && log_success "CronJob deleted (or was not present)" \
  || log_warning "CronJob deletion may have failed — continuing"

kubectl delete jobs --all \
  -n "${MINIO_NAMESPACE}" \
  --ignore-not-found 2>/dev/null \
  && log_success "Jobs deleted" \
  || log_warning "Job deletion may have failed — continuing"

# Wait for CronJob-spawned pods to finish terminating
kubectl wait --for=delete pod \
  -l "batch.kubernetes.io/controller-uid" \
  -n "${MINIO_NAMESPACE}" \
  --timeout=60s 2>/dev/null || true

echo ""

# ============================================================================
# Remove in-cluster MinIO Tenant
# ============================================================================

log_info "Deleting in-cluster MinIO Tenant '${MINIO_TENANT_NAME}'..."
kubectl delete tenant.minio.min.io "${MINIO_TENANT_NAME}" \
  -n "${MINIO_NAMESPACE}" \
  --ignore-not-found \
  && log_success "MinIO Tenant deleted (or was not present)" \
  || log_warning "MinIO Tenant deletion may have failed — continuing"

echo "⏳ Waiting for MinIO pods to terminate..."
kubectl wait --for=delete pod \
  -l app=minio \
  -n "${MINIO_NAMESPACE}" \
  --timeout=180s 2>/dev/null \
  && log_success "MinIO pods terminated" \
  || log_warning "Timeout waiting for pod termination — continuing"

echo ""

# ============================================================================
# Patch Secrets
# ============================================================================

log_info "Encoding credentials..."
ACCESS_KEY_B64=$(encode_base64 "${MINIO_ACCESS_KEY}")
SECRET_KEY_B64=$(encode_base64 "${MINIO_SECRET_KEY}")

log_info "Patching minio-credentials in namespace '${AIWB_NAMESPACE}'..."
kubectl patch secret minio-credentials -n "${AIWB_NAMESPACE}" --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/minio-access-key\", \"value\": \"${ACCESS_KEY_B64}\"},
  {\"op\": \"replace\", \"path\": \"/data/minio-secret-key\", \"value\": \"${SECRET_KEY_B64}\"}
]" && log_success "aiwb/minio-credentials updated" || log_warning "aiwb/minio-credentials patch may have failed"

log_info "Patching minio-credentials in namespace '${WORKBENCH_NAMESPACE}'..."
kubectl patch secret minio-credentials -n "${WORKBENCH_NAMESPACE}" --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/minio-access-key\", \"value\": \"${ACCESS_KEY_B64}\"},
  {\"op\": \"replace\", \"path\": \"/data/minio-secret-key\", \"value\": \"${SECRET_KEY_B64}\"}
]" && log_success "workbench/minio-credentials updated" || log_warning "workbench/minio-credentials patch may have failed"

# ============================================================================
# Patch AIWB Deployment
# ============================================================================

log_info "Updating AIWB deployment MINIO_URL and MINIO_BUCKET..."
kubectl set env deployment/aiwb-api -n "${AIWB_NAMESPACE}" \
  MINIO_URL="http://${MINIO_HOST}:${MINIO_PORT}" \
  MINIO_BUCKET="${MINIO_BUCKET}" \
  && log_success "AIWB deployment env vars updated" \
  || log_warning "AIWB deployment env update may have failed"

# ============================================================================
# Restart and Wait
# ============================================================================

log_info "Restarting AIWB deployment..."
kubectl rollout restart deployment/aiwb-api -n "${AIWB_NAMESPACE}" \
  && log_success "AIWB deployment restarted" \
  || log_warning "AIWB deployment restart may have failed"

log_info "Waiting for AIWB rollout to complete..."
kubectl rollout status deployment/aiwb-api -n "${AIWB_NAMESPACE}" --timeout=300s

# ============================================================================
# Verification
# ============================================================================

echo ""
echo "Current AIWB MinIO configuration:"
kubectl get deployment aiwb-api -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_URL")].value}' \
  2>/dev/null | xargs -I {} echo "  MINIO_URL:    {}"
kubectl get deployment aiwb-api -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_BUCKET")].value}' \
  2>/dev/null | xargs -I {} echo "  MINIO_BUCKET: {}"

echo ""
kubectl get secret minio-credentials -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.data.minio-access-key}' 2>/dev/null \
  | base64 -d | xargs -I {} echo "  aiwb/minio-credentials access-key: {}"

echo ""
echo "=========================================================================="
echo "BYO S3 Override Complete"
echo "=========================================================================="
echo ""
echo "External MinIO: http://${MINIO_HOST}:${MINIO_PORT}"
echo ""
echo "Next steps:"
echo "  kubectl get pods -n ${AIWB_NAMESPACE}"
echo "  kubectl logs -n ${AIWB_NAMESPACE} deployment/aiwb-api -c aiwb-api | grep -i minio"
echo ""
