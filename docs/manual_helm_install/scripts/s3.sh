#!/bin/bash

# Pluggable S3 Override Script — Proof-of-Concept
# Removes the in-cluster MinIO Tenant and patches Kubernetes resources so that
# AIWB connects to an external MinIO-compatible object storage instead.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
# Host port external MinIO publishes its S3 API on. Default 19000 matches the
# minio-byo container layout used in this dev workflow (container :9000 → host :19000).
MINIO_PORT="${MINIO_PORT:-19000}"
# IP that backs the redirect Endpoints. Defaults to the Rancher Desktop host IP.
# Override with MINIO_HOST_IP=<ip> for other engines (kind, minikube, etc).
MINIO_HOST_IP="${MINIO_HOST_IP:-192.168.127.254}"
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
echo "  Pluggable S3 Override — External MinIO Configuration"
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
# Create redirect Service for in-cluster minio name → external host
# ============================================================================
# Forwards http://minio.minio-tenant-default.svc.cluster.local:80 to
# ${MINIO_HOST}:${MINIO_PORT} so aim-performance workloads (and any other
# in-cluster consumer that bakes in the in-cluster URL via env vars like
# BUCKET_STORAGE_HOST) reach the external MinIO transparently.
# aiwb-api itself is set directly to ${MINIO_HOST}:${MINIO_PORT} below and
# does not depend on this redirect.
#
# DOC NOTE: The "default-user" secret in ${MINIO_NAMESPACE} (created by
# install_base.sh from secrets-aiwb.yaml / secrets-override-hardcoded.yaml)
# was consumed by the in-cluster MinIO Tenant which is now gone. It is left
# in place harmlessly — nothing reads it after the Tenant is deleted.

log_info "Creating in-cluster redirect Service for external MinIO..."

# Ensure the namespace exists (s3.sh may run before in-cluster MinIO was ever installed)
kubectl create namespace "${MINIO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log_info "Redirect target: ${MINIO_HOST_IP}:${MINIO_PORT} (override with MINIO_HOST_IP=<ip>)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  ports:
  - name: http-minio
    port: 80
    targetPort: ${MINIO_PORT}
    protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
subsets:
- addresses:
  - ip: ${MINIO_HOST_IP}
  ports:
  - name: http-minio
    port: ${MINIO_PORT}
    protocol: TCP
EOF
log_success "In-cluster MinIO redirect Service ready"

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
# Ensure workbench namespace has the project-id label AIWB requires
# ============================================================================
# aiwb-api rejects requests to a workbench namespace that lacks the
# airm.silogen.ai/project-id label (see aiwb security.py: "is not a workbench
# namespace (missing project-id label)"). The label is normally set by the
# AIWB chart's templates/namespace.yaml during install_base.sh, but on partial
# re-installs (e.g. when SSA conflicts with manually-set fields cause the
# helm apply to abort) the label can end up missing on the existing namespace.
# This step idempotently restores it: --overwrite=false preserves any existing
# project-id, and adds a fresh UUID only when the label is absent.

log_info "Ensuring workbench namespace has project-id label..."
PROJECT_ID_LABEL="airm.silogen.ai/project-id"
EXISTING_PROJECT_ID=$(kubectl get namespace "${WORKBENCH_NAMESPACE}" \
  -o jsonpath="{.metadata.labels.${PROJECT_ID_LABEL//./\\.}}" 2>/dev/null || echo "")
if [[ -n "${EXISTING_PROJECT_ID}" ]]; then
  log_success "workbench namespace already has ${PROJECT_ID_LABEL}=${EXISTING_PROJECT_ID}"
else
  NEW_PROJECT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  kubectl label namespace "${WORKBENCH_NAMESPACE}" \
    "${PROJECT_ID_LABEL}=${NEW_PROJECT_ID}" --overwrite=false \
    && log_success "workbench namespace labeled ${PROJECT_ID_LABEL}=${NEW_PROJECT_ID}" \
    || log_warning "Failed to label workbench namespace"
fi

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
echo "PLUGGABLE S3 Override Complete"
echo "=========================================================================="
echo ""
echo "External MinIO: http://${MINIO_HOST}:${MINIO_PORT}"
echo ""
echo "Next steps:"
echo "  kubectl get pods -n ${AIWB_NAMESPACE}"
echo "  kubectl logs -n ${AIWB_NAMESPACE} deployment/aiwb-api -c aiwb-api | grep -i minio"
echo ""
