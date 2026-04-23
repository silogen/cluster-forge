#!/bin/bash

# Sets up an external MinIO instance directly on the host via Homebrew.
# Run this BEFORE scripts/s3.sh to prepare the external object storage.
#
# After this script completes, run scripts/s3.sh with the printed environment variables.
#
# Note: Kubernetes pods reach the host via host.docker.internal, not localhost.
# Make sure MinIO listens on 0.0.0.0 (the default) and that your firewall
# allows connections on MINIO_API_PORT from the Kubernetes pod CIDR.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

MINIO_API_PORT="${MINIO_API_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-examplepass}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-examplepass}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-${HOME}/minio-data}"

REQUIRED_BUCKETS=("default-bucket" "models" "datasets")

# ============================================================================
# Helpers
# ============================================================================

log_info()    { echo "📦 $1"; }
log_success() { echo "✅ $1"; }
log_warning() { echo "⚠️  $1"; }
log_error()   { echo "❌ $1" >&2; }

minio_is_ready() {
  curl -sf "http://localhost:${MINIO_API_PORT}/minio/health/live" >/dev/null 2>&1
}

mc_cmd() {
  MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:${MINIO_API_PORT}" \
    mc "$@"
}

# ============================================================================
# Preflight
# ============================================================================

echo ""
echo "=========================================================================="
echo "  MinIO Homebrew Host Setup"
echo "=========================================================================="
echo "  API port:     ${MINIO_API_PORT}"
echo "  Console port: ${MINIO_CONSOLE_PORT}"
echo "  Data dir:     ${MINIO_DATA_DIR}"
echo "=========================================================================="
echo ""

if ! command -v brew >/dev/null 2>&1; then
  log_error "Homebrew not found. Install it from https://brew.sh"
  exit 1
fi
log_success "Homebrew found: $(brew --version | head -1)"

# ============================================================================
# Install MinIO and mc
# ============================================================================

if ! command -v minio >/dev/null 2>&1; then
  log_info "Installing MinIO server..."
  brew tap minio/stable 2>/dev/null || true
  brew install minio/stable/minio
  log_success "MinIO installed"
else
  log_success "MinIO already installed: $(minio --version 2>/dev/null | head -1)"
fi

if ! command -v mc >/dev/null 2>&1; then
  log_info "Installing MinIO Client (mc)..."
  brew install minio/stable/mc 2>/dev/null || brew install mc
  log_success "mc installed"
else
  log_success "mc already installed: $(mc --version 2>/dev/null | head -1)"
fi

# ============================================================================
# Prepare data directory
# ============================================================================

mkdir -p "${MINIO_DATA_DIR}"
log_success "Data directory: ${MINIO_DATA_DIR}"

# ============================================================================
# Start MinIO if not already running
# ============================================================================

if minio_is_ready; then
  log_success "MinIO is already running on port ${MINIO_API_PORT}"
else
  log_info "Starting MinIO server on port ${MINIO_API_PORT}..."

  # Check if port is in use by something else
  if lsof -iTCP:"${MINIO_API_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    log_error "Port ${MINIO_API_PORT} is already in use by another process."
    echo "  Set MINIO_API_PORT to a different port and retry."
    exit 1
  fi

  MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
    minio server "${MINIO_DATA_DIR}" \
      --address ":${MINIO_API_PORT}" \
      --console-address ":${MINIO_CONSOLE_PORT}" \
      >/tmp/minio-byo.log 2>&1 &

  MINIO_PID=$!
  echo "${MINIO_PID}" > /tmp/minio-byo.pid
  log_info "MinIO started (PID ${MINIO_PID}), waiting for it to be ready..."

  for i in $(seq 1 30); do
    if minio_is_ready; then
      log_success "MinIO is ready"
      break
    fi
    if [ "$i" -eq 30 ]; then
      log_error "MinIO did not become ready in time. Check /tmp/minio-byo.log"
      exit 1
    fi
    sleep 2
  done
fi

# ============================================================================
# Create required buckets
# ============================================================================

log_info "Creating required buckets..."
for bucket in "${REQUIRED_BUCKETS[@]}"; do
  if mc_cmd ls "local/${bucket}" >/dev/null 2>&1; then
    log_success "Bucket '${bucket}' already exists"
  else
    mc_cmd mb "local/${bucket}" >/dev/null \
      && log_success "Bucket '${bucket}' created" \
      || { log_error "Failed to create bucket '${bucket}'"; exit 1; }
  fi
done

# ============================================================================
# Done
# ============================================================================

echo ""
echo "=========================================================================="
echo "✅ MinIO host process is ready"
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
echo ""
if [ -f /tmp/minio-byo.pid ]; then
  echo "  MinIO was started by this script (PID $(cat /tmp/minio-byo.pid))."
  echo "  Logs: /tmp/minio-byo.log"
  echo "  To stop: kill $(cat /tmp/minio-byo.pid)"
  echo ""
fi
echo "  To start automatically on login, use a brew service (macOS only):"
echo "    MINIO_ROOT_USER=${MINIO_ROOT_USER} MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD} \\"
echo "    brew services start minio/stable/minio"
echo ""
echo "  WSL — firewall note: if Kubernetes is on Windows (Rancher/Docker Desktop),"
echo "  allow port ${MINIO_API_PORT} through Windows Firewall:"
echo "    New-NetFirewallRule -DisplayName 'WSL MinIO' -Direction Inbound \\"
echo "      -LocalPort ${MINIO_API_PORT} -Protocol TCP -Action Allow"
echo ""
echo "  Run scripts/s3.sh with:"
echo ""
echo "    MINIO_HOST=host.docker.internal \\"
echo "    MINIO_PORT=${MINIO_API_PORT} \\"
echo "    MINIO_ACCESS_KEY=${MINIO_ROOT_USER} \\"
echo "    MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD} \\"
echo "    ./BYO/scripts/s3.sh"
echo ""
echo "=========================================================================="
