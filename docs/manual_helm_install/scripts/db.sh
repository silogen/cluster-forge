#!/bin/bash

# Pluggable Database Override Script for Kubernetes
# This script patches Kubernetes resources to use an external PostgreSQL database
# instead of the in-cluster CNPG (CloudNativePG) instances

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# External PostgreSQL database settings
# Use host.docker.internal for Kubernetes pods to reach WSL PostgreSQL
POSTGRES_HOST="${POSTGRES_HOST:-host.docker.internal}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# AIWB database credentials
AIWB_DB_NAME="${AIWB_DB_NAME:-aiwb}"
AIWB_DB_USER="${AIWB_DB_USER:-aiwb_user}"
AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"

# Keycloak database credentials
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloak}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"

# Kubernetes context
KUBE_CONTEXT="${KUBE_CONTEXT:-rancher-desktop}"

# Namespaces
AIWB_NAMESPACE="aiwb"
KEYCLOAK_NAMESPACE="keycloak"

# ============================================================================
# Functions
# ============================================================================

log_info() {
  echo "📦 $1"
}

log_success() {
  echo "✅ $1"
}

log_error() {
  echo "❌ $1" >&2
}

log_warning() {
  echo "⚠️  $1"
}

check_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
  fi
}

check_context() {
  local current_context=$(kubectl config current-context 2>/dev/null || echo "")
  if [ "${current_context}" != "${KUBE_CONTEXT}" ]; then
    log_warning "Current context is '${current_context}', expected '${KUBE_CONTEXT}'"
    log_info "Switching to context '${KUBE_CONTEXT}'..."
    kubectl config use-context "${KUBE_CONTEXT}" || {
      log_error "Failed to switch to context '${KUBE_CONTEXT}'"
      exit 1
    }
  fi
  log_success "Using kubectl context: ${KUBE_CONTEXT}"
}

encode_base64() {
  echo -n "$1" | base64 -w 0
}

# ============================================================================
# Main Script
# ============================================================================

echo ""
echo "=========================================================================="
echo "  Pluggable Database Override — External PostgreSQL Configuration"
echo "=========================================================================="
echo "  External PostgreSQL: ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "  AIWB database:       ${AIWB_DB_NAME} (user: ${AIWB_DB_USER})"
echo "  Keycloak database:   ${KEYCLOAK_DB_NAME} (user: ${KEYCLOAK_DB_USER})"
echo "=========================================================================="
echo ""

check_kubectl
check_context

# ============================================================================
# WARNING: Destructive step — delete in-cluster CNPG clusters
# ============================================================================

echo ""
echo "=========================================================================="
echo "⚠️  WARNING: DESTRUCTIVE OPERATION — DATA LOSS"
echo "=========================================================================="
echo "  This script will DELETE the in-cluster PostgreSQL clusters:"
echo "    - aiwb-infra-cnpg-cnpg  (namespace: aiwb)"
echo "    - keycloak-cnpg         (namespace: keycloak)"
echo ""
echo "  ALL database data (AIWB and Keycloak) will be permanently lost."
echo "  This action CANNOT be undone."
echo ""
echo "  Before continuing, ensure:"
echo "    1. All data has been backed up or is not needed"
echo "    2. External PostgreSQL is running at ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "    3. AIWB database '${AIWB_DB_NAME}' exists with user '${AIWB_DB_USER}'"
echo "    4. Keycloak database '${KEYCLOAK_DB_NAME}' exists with user '${KEYCLOAK_DB_USER}'"
echo "=========================================================================="
echo ""
read -r -p "Type 'yes' to confirm data loss and proceed: " confirm
if [[ "${confirm}" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi
echo ""

# ============================================================================
# Remove in-cluster CNPG clusters
# ============================================================================

log_info "Deleting in-cluster CNPG cluster 'aiwb-infra-cnpg-cnpg' (namespace: aiwb)..."
kubectl delete cluster -n aiwb aiwb-infra-cnpg-cnpg --ignore-not-found \
  && log_success "AIWB CNPG cluster deleted (or was not present)" \
  || log_warning "AIWB CNPG cluster deletion may have failed — continuing"

log_info "Deleting in-cluster CNPG cluster 'keycloak-cnpg' (namespace: keycloak)..."
kubectl delete cluster -n keycloak keycloak-cnpg --ignore-not-found \
  && log_success "Keycloak CNPG cluster deleted (or was not present)" \
  || log_warning "Keycloak CNPG cluster deletion may have failed — continuing"

echo "⏳ Waiting for AIWB database pods to terminate..."
kubectl wait --for=delete pod \
  -l "cnpg.io/cluster=aiwb-infra-cnpg-cnpg" \
  -n aiwb \
  --timeout=120s 2>/dev/null \
  && log_success "AIWB database pods terminated" \
  || log_warning "Timeout waiting for AIWB database pod termination — continuing"

echo "⏳ Waiting for Keycloak database pods to terminate..."
kubectl wait --for=delete pod \
  -l "cnpg.io/cluster=keycloak-cnpg" \
  -n keycloak \
  --timeout=120s 2>/dev/null \
  && log_success "Keycloak database pods terminated" \
  || log_warning "Timeout waiting for Keycloak database pod termination — continuing"

echo ""

# ============================================================================
# Patch AIWB Secrets
# ============================================================================

log_info "Patching AIWB database secret..."

kubectl patch secret aiwb-cnpg-user -n "${AIWB_NAMESPACE}" --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/username\", \"value\": \"$(encode_base64 "${AIWB_DB_USER}")\"},
  {\"op\": \"replace\", \"path\": \"/data/password\", \"value\": \"$(encode_base64 "${AIWB_DB_PASSWORD}")\"}
]" 2>/dev/null && log_success "AIWB secret updated" || log_warning "AIWB secret patch may have failed"

# ============================================================================
# Patch AIWB Deployment
# ============================================================================

log_info "Patching AIWB API deployment..."

# Get current deployment spec
DEPLOYMENT_NAME="aiwb-api"

# Patch environment variables for database connection
kubectl set env deployment/${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" \
  DATABASE_HOST="${POSTGRES_HOST}" \
  DATABASE_PORT="${POSTGRES_PORT}" \
  DATABASE_NAME="${AIWB_DB_NAME}" \
  DATABASE_USER="${AIWB_DB_USER}" \
  >/dev/null 2>&1 && log_success "AIWB deployment environment variables updated" || log_warning "Failed to update deployment env vars"

# Patch wait-for-db init container to use correct database host
log_info "Patching AIWB wait-for-db init container..."
kubectl patch deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/0/command/2\",
    \"value\": \"until pg_isready -h \\\"${POSTGRES_HOST}\\\" -p ${POSTGRES_PORT} -U ${AIWB_DB_USER}; do\\n  echo \\\"Waiting for database...\\\"\\n  sleep 2\\ndone\\necho \\\"Database is ready!\\\"\\n\"
  }
]" 2>/dev/null && log_success "AIWB wait-for-db init container updated" || log_warning "wait-for-db init container patch may have failed"

# Patch liquibase-migrate init container URL to use correct database host
log_info "Patching AIWB liquibase-migrate init container..."
kubectl patch deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/2/command/1\",
    \"value\": \"--url=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${AIWB_DB_NAME}\"
  }
]" 2>/dev/null && log_success "AIWB liquibase-migrate init container updated" || log_warning "liquibase-migrate init container patch may have failed"

# ============================================================================
# Patch Keycloak Secrets
# ============================================================================

log_info "Patching Keycloak database secret..."

kubectl patch secret keycloak-cnpg-user -n "${KEYCLOAK_NAMESPACE}" --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/username\", \"value\": \"$(encode_base64 "${KEYCLOAK_DB_USER}")\"},
  {\"op\": \"replace\", \"path\": \"/data/password\", \"value\": \"$(encode_base64 "${KEYCLOAK_DB_PASSWORD}")\"}
]" 2>/dev/null && log_success "Keycloak secret updated" || log_warning "Keycloak secret patch may have failed"

# ============================================================================
# Patch Keycloak Deployment
# ============================================================================

log_info "Patching Keycloak deployment..."

KEYCLOAK_DEPLOYMENT="keycloak"

# Patch environment variables for database connection
kubectl set env deployment/${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" \
  KC_DB_URL_HOST="${POSTGRES_HOST}" \
  KC_DB_URL_PORT="${POSTGRES_PORT}" \
  KC_DB_URL_DATABASE="${KEYCLOAK_DB_NAME}" \
  >/dev/null 2>&1 && log_success "Keycloak deployment environment variables updated" || log_warning "Failed to update Keycloak env vars"

# ============================================================================
# Restart Deployments
# ============================================================================

log_info "Restarting deployments to apply changes..."

kubectl rollout restart deployment/${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" >/dev/null 2>&1 && \
  log_success "AIWB API deployment restarted" || log_warning "Failed to restart AIWB deployment"

kubectl rollout restart deployment/${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" >/dev/null 2>&1 && \
  log_success "Keycloak deployment restarted" || log_warning "Failed to restart Keycloak deployment"

# ============================================================================
# Wait for Rollouts
# ============================================================================

log_info "Waiting for deployments to be ready..."

kubectl rollout status deployment/${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" --timeout=300s 2>&1 | grep -v "Waiting for" | tail -1
kubectl rollout status deployment/${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" --timeout=300s 2>&1 | grep -v "Waiting for" | tail -1

log_success "Deployments rolled out successfully"

# ============================================================================
# Verification
# ============================================================================

log_info "Verifying configuration..."

echo ""
echo "AIWB API Environment:"
kubectl get deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DATABASE_HOST")].value}' 2>/dev/null | xargs -I {} echo "  DATABASE_HOST: {}"
kubectl get deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DATABASE_PORT")].value}' 2>/dev/null | xargs -I {} echo "  DATABASE_PORT: {}"
kubectl get deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DATABASE_NAME")].value}' 2>/dev/null | xargs -I {} echo "  DATABASE_NAME: {}"
kubectl get deployment ${DEPLOYMENT_NAME} -n "${AIWB_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DATABASE_USER")].value}' 2>/dev/null | xargs -I {} echo "  DATABASE_USER: {}"

echo ""
echo "Keycloak Environment:"
kubectl get deployment ${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_DB_URL_HOST")].value}' 2>/dev/null | xargs -I {} echo "  KC_DB_URL_HOST: {}"
kubectl get deployment ${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_DB_URL_PORT")].value}' 2>/dev/null | xargs -I {} echo "  KC_DB_URL_PORT: {}"
kubectl get deployment ${KEYCLOAK_DEPLOYMENT} -n "${KEYCLOAK_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KC_DB_URL_DATABASE")].value}' 2>/dev/null | xargs -I {} echo "  KC_DB_URL_DATABASE: {}"

echo ""
echo "Secret Status:"
kubectl get secret aiwb-cnpg-user -n "${AIWB_NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d | xargs -I {} echo "  AIWB username: {}"
kubectl get secret keycloak-cnpg-user -n "${KEYCLOAK_NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d | xargs -I {} echo "  Keycloak username: {}"

echo ""
echo "=========================================================================="
echo "Pluggable Database Override Complete"
echo "=========================================================================="
echo ""
echo "External Database Configuration:"
echo "  Host: ${POSTGRES_HOST}"
echo "  Port: ${POSTGRES_PORT}"
echo ""
echo "AIWB Database:"
echo "  Database: ${AIWB_DB_NAME}"
echo "  Username: ${AIWB_DB_USER}"
echo ""
echo "Keycloak Database:"
echo "  Database: ${KEYCLOAK_DB_NAME}"
echo "  Username: ${KEYCLOAK_DB_USER}"
echo ""
echo "Next Steps:"
echo "  1. Monitor pod status: kubectl get pods -n ${AIWB_NAMESPACE} && kubectl get pods -n ${KEYCLOAK_NAMESPACE}"
echo "  2. Check logs if pods fail: kubectl logs -n ${AIWB_NAMESPACE} deployment/${DEPLOYMENT_NAME}"
echo "  3. Verify database connectivity from pods"
echo ""
echo "Database host is set to: ${POSTGRES_HOST}"
echo "To use a different host, run: POSTGRES_HOST=your-host ./db.sh"
echo ""
echo "IMPORTANT: PostgreSQL must be listening on 0.0.0.0 (all interfaces)"
echo "Check with: psql -U postgres -c \"SHOW listen_addresses\""
echo ""
echo "=========================================================================="
