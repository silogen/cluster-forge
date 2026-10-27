#!/bin/bash

# Sets up an external MinIO instance as a Docker container.
# Run this BEFORE scripts/pluggable.sh to prepare the external object storage.
#
# After this script completes, run scripts/pluggable.sh with PLUGGABLE_S3=true
# and the printed environment variables. Then optionally run scripts/s3.sh for
# post-install verification.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

CONTAINER_NAME="${CONTAINER_NAME:-minio-pluggable}"
MINIO_API_PORT="${MINIO_API_PORT:-9999}"        # host port for S3 API
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}" # host port for web console
MINIO_ROOT_USER="${MINIO_ROOT_USER:-examplepass}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-examplepass}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-${HOME}/minio-data}"
MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:latest}"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:latest}"

REQUIRED_BUCKETS=("default-bucket" "models" "datasets")

# ============================================================================
# Helpers
# ============================================================================

log_info()    { echo "📦 $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error()   { echo "❌ $1" >&2; }

mc_run() {
  docker run --rm --network host \
    -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:${MINIO_API_PORT}" \
    "${MC_IMAGE}" "$@"
}

# ============================================================================
# Preflight
# ============================================================================

echo ""
echo "=========================================================================="
echo "  MinIO Docker Container Setup"
echo "=========================================================================="
echo "  Container:    ${CONTAINER_NAME}"
echo "  API port:     ${MINIO_API_PORT}"
echo "  Console port: ${MINIO_CONSOLE_PORT}"
echo "  Data dir:     ${MINIO_DATA_DIR}"
echo "=========================================================================="
echo ""

if ! command -v docker >/dev/null 2>&1; then
  log_error "docker not found. Please install Docker."
  exit 1
fi
log_success "docker found"

# Check if API port is available
if docker run --rm --network host "${MC_IMAGE}" ping localhost --port "${MINIO_API_PORT}" >/dev/null 2>&1; then
  log_warning "Port ${MINIO_API_PORT} appears to be in use. Set MINIO_API_PORT to override."
fi

# ============================================================================
# Start MinIO container
# ============================================================================

mkdir -p "${MINIO_DATA_DIR}"

if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  log_info "Container '${CONTAINER_NAME}' already exists — removing it..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

log_info "Starting MinIO container '${CONTAINER_NAME}'..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${MINIO_API_PORT}:9000" \
  -p "${MINIO_CONSOLE_PORT}:9001" \
  -e MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -e MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  -v "${MINIO_DATA_DIR}:/data" \
  "${MINIO_IMAGE}" server /data --console-address ":9001" \
  >/dev/null

log_success "Container started"

# ============================================================================
# Wait for MinIO to be ready
# ============================================================================

log_info "Waiting for MinIO to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${MINIO_API_PORT}/minio/health/live" >/dev/null 2>&1; then
    log_success "MinIO is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    log_error "MinIO did not become ready in time. Check: docker logs ${CONTAINER_NAME}"
    exit 1
  fi
  sleep 2
done

# ============================================================================
# Create required buckets
# ============================================================================

log_info "Creating required buckets..."
for bucket in "${REQUIRED_BUCKETS[@]}"; do
  if mc_run ls "local/${bucket}" >/dev/null 2>&1; then
    log_success "Bucket '${bucket}' already exists"
  else
    mc_run mb "local/${bucket}" >/dev/null \
      && log_success "Bucket '${bucket}' created" \
      || { log_error "Failed to create bucket '${bucket}'"; exit 1; }
  fi
done

# ============================================================================
# Done
# ============================================================================

echo ""
echo "=========================================================================="
echo "✅ MinIO Docker Container is ready"
echo "=========================================================================="
echo ""
echo "  API:     http://localhost:${MINIO_API_PORT}"
echo "  Console: http://localhost:${MINIO_CONSOLE_PORT}"
echo "  User:    ${MINIO_ROOT_USER}"
echo "  Data:    ${MINIO_DATA_DIR}"
echo ""
echo "  Buckets: $(IFS=', '; echo "${REQUIRED_BUCKETS[*]}")"
echo ""
echo "  From Kubernetes pods, use:  host.docker.internal:${MINIO_API_PORT}"
echo "  (Supported on Rancher Desktop and Docker Desktop.)"
echo "  On Minikube/Kind, use the host IP instead of host.docker.internal."
echo ""
echo "  Run scripts/pluggable.sh with:"
echo ""
echo "    PLUGGABLE_S3=true \\"
echo "    MINIO_HOST=host.docker.internal \\"
echo "    MINIO_PORT=${MINIO_API_PORT} \\"
echo "    MINIO_API_ACCESS_KEY=${MINIO_ROOT_USER} \\"
echo "    MINIO_API_SECRET_KEY=${MINIO_ROOT_PASSWORD} \\"
echo "    ./scripts/pluggable.sh <DOMAIN>"
echo ""
echo "  To stop the container:"
echo "    docker stop ${CONTAINER_NAME}"
echo ""
echo "  To start it again after a reboot (--restart unless-stopped is set):"
echo "    docker start ${CONTAINER_NAME}"
echo "=========================================================================="
