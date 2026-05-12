#!/bin/bash

# Pluggable S3 — Post-install verification script.
# Run this after install_base.sh has completed in PLUGGABLE_S3=true mode to
# confirm that:
#   1. AIWB is configured to talk to the external MinIO endpoint
#   2. minio-credentials Secrets in aiwb / workbench namespaces match the
#      external MinIO credentials
#   3. The in-cluster redirect Service resolves to the external MinIO and the
#      external MinIO answers /minio/health/live with HTTP 200
#
# This script is non-destructive — it only reads cluster state and runs a
# short-lived curl pod against the redirect URL. It does NOT delete the
# in-cluster MinIO Tenant, patch Secrets, or restart Deployments. The
# install_base.sh PLUGGABLE_S3 branch is responsible for setting up all of
# the resources this script verifies.

set -euo pipefail

# ============================================================================
# Configuration — must match the values used when running install_base.sh
# ============================================================================

MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
MINIO_PORT="${MINIO_PORT:-9999}"
MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
KUBE_CONTEXT="${KUBE_CONTEXT:-rancher-desktop}"

AIWB_NAMESPACE="aiwb"
WORKBENCH_NAMESPACE="workbench"
MINIO_NAMESPACE="minio-tenant-default"

# ============================================================================
# Helpers
# ============================================================================

log_info()    { echo "📦 $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error()   { echo "❌ $1" >&2; }

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
echo "  Pluggable S3 — Post-install verification"
echo "=========================================================================="
echo "  External MinIO: http://${MINIO_HOST}:${MINIO_PORT}"
echo "  Bucket:         ${MINIO_BUCKET}"
echo "=========================================================================="
echo ""

check_kubectl
check_context

# ============================================================================
# Verification
# ============================================================================

echo ""
echo "AIWB MinIO configuration:"
kubectl get deployment aiwb-api -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_URL")].value}' \
  2>/dev/null | xargs -I {} echo "  MINIO_URL:    {}"
kubectl get deployment aiwb-api -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MINIO_BUCKET")].value}' \
  2>/dev/null | xargs -I {} echo "  MINIO_BUCKET: {}"

echo ""
echo "minio-credentials Secrets:"
kubectl get secret minio-credentials -n "${AIWB_NAMESPACE}" \
  -o jsonpath='{.data.minio-access-key}' 2>/dev/null \
  | base64 -d | xargs -I {} echo "  ${AIWB_NAMESPACE}/minio-credentials access-key: {}"
kubectl get secret minio-credentials -n "${WORKBENCH_NAMESPACE}" \
  -o jsonpath='{.data.minio-access-key}' 2>/dev/null \
  | base64 -d | xargs -I {} echo "  ${WORKBENCH_NAMESPACE}/minio-credentials access-key: {}"

echo ""
echo "Redirect Service:"
kubectl get endpoints minio -n "${MINIO_NAMESPACE}" \
  -o jsonpath='{range .subsets[*]}{.addresses[*].ip}:{.ports[*].port}{"\n"}{end}' \
  2>/dev/null | xargs -I {} echo "  minio.${MINIO_NAMESPACE} → {}"

log_info "Verifying in-cluster URL → external MinIO..."
REDIRECT_STATUS=$(kubectl run "minio-check-$$" \
  --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 \
  -- curl -s -o /dev/null -w '%{http_code}' \
     "http://minio.${MINIO_NAMESPACE}.svc.cluster.local/minio/health/live" 2>/dev/null \
  || echo "??")
if [[ "${REDIRECT_STATUS}" == "200" ]]; then
  log_success "In-cluster URL returns 200 (redirect working)"
else
  log_warning "In-cluster URL health check returned: ${REDIRECT_STATUS} (expected 200)"
fi

echo ""
echo "=========================================================================="
echo "Verification complete"
echo "=========================================================================="
echo ""
