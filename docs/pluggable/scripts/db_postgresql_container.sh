#!/bin/bash

# Pluggable Database Setup Script for AIWB
# This script sets up PostgreSQL in a Docker container on WSL
# and configures it to accept connections from Kubernetes Pods
# Prerequisites: Docker installed and running on WSL

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Container settings
CONTAINER_NAME="${POSTGRES_CONTAINER_NAME:-aiwb-postgres}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Database connection settings
POSTGRES_ADMIN_USER="postgres"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-postgres}"

# Application database settings
AIWB_DB_NAME="aiwb"
AIWB_DB_USER="aiwb_user"
AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"

KEYCLOAK_DB_NAME="keycloak"
KEYCLOAK_DB_USER="keycloak"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"

# Network settings for Kubernetes Pod access
# K8s pods will use host.docker.internal to connect
K8S_DB_HOST="host.docker.internal"

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

# ============================================================================
# Check Prerequisites
# ============================================================================

log_info "Checking prerequisites..."

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is not installed. Please install Docker first."
  log_error "Visit: https://docs.docker.com/desktop/wsl/"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log_error "Docker is not running. Please start Docker first."
  exit 1
fi

log_success "Docker is installed and running"

# ============================================================================
# Setup PostgreSQL Container
# ============================================================================

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  log_info "Container '${CONTAINER_NAME}' already exists"

  # Check if it's running
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_info "Container is already running"
  else
    log_info "Starting existing container..."
    docker start "${CONTAINER_NAME}"
    sleep 3
  fi
else
  log_info "Creating PostgreSQL container '${CONTAINER_NAME}'..."

  # Create and start PostgreSQL container
  # Using port mapping to allow K8s pod connections via host.docker.internal
  docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${POSTGRES_PORT}:5432" \
    -e POSTGRES_PASSWORD="${POSTGRES_ADMIN_PASSWORD}" \
    -e POSTGRES_USER="${POSTGRES_ADMIN_USER}" \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -v "${CONTAINER_NAME}-data:/var/lib/postgresql/data" \
    postgres:${POSTGRES_VERSION} \
    -c listen_addresses='0.0.0.0' \
    -c max_connections=200

  log_success "PostgreSQL container created and started"

  log_info "Waiting for PostgreSQL to be ready..."
  sleep 5
fi

# Wait for PostgreSQL to be ready
MAX_RETRIES=30
RETRY_COUNT=0
while ! docker exec "${CONTAINER_NAME}" pg_isready -U "${POSTGRES_ADMIN_USER}" >/dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]; then
    log_error "PostgreSQL failed to start after ${MAX_RETRIES} retries"
    docker logs "${CONTAINER_NAME}" --tail 50
    exit 1
  fi
  log_info "Waiting for PostgreSQL to be ready... (${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 2
done

log_success "PostgreSQL server is ready"

# ============================================================================
# Create AIWB Database and User
# ============================================================================

log_info "Creating AIWB database and user..."

docker exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_ADMIN_USER}" -d postgres <<EOF
-- Create AIWB user if it doesn't exist
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '${AIWB_DB_USER}') THEN
    CREATE USER ${AIWB_DB_USER} WITH PASSWORD '${AIWB_DB_PASSWORD}';
  ELSE
    ALTER USER ${AIWB_DB_USER} WITH PASSWORD '${AIWB_DB_PASSWORD}';
  END IF;
END
\$\$;

-- Create AIWB database if it doesn't exist
SELECT 'CREATE DATABASE ${AIWB_DB_NAME} OWNER ${AIWB_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${AIWB_DB_NAME}')\gexec

-- Grant all privileges on AIWB database to AIWB user
GRANT ALL PRIVILEGES ON DATABASE ${AIWB_DB_NAME} TO ${AIWB_DB_USER};
EOF

# Grant schema privileges for AIWB database
docker exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_ADMIN_USER}" -d "${AIWB_DB_NAME}" <<EOF
-- Grant schema privileges
GRANT ALL ON SCHEMA public TO ${AIWB_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${AIWB_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${AIWB_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${AIWB_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${AIWB_DB_USER};
EOF

log_success "AIWB database and user created"

# ============================================================================
# Create Keycloak Database and User
# ============================================================================

log_info "Creating Keycloak database and user..."

docker exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_ADMIN_USER}" -d postgres <<EOF
-- Create Keycloak user if it doesn't exist
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '${KEYCLOAK_DB_USER}') THEN
    CREATE USER ${KEYCLOAK_DB_USER} WITH PASSWORD '${KEYCLOAK_DB_PASSWORD}';
  ELSE
    ALTER USER ${KEYCLOAK_DB_USER} WITH PASSWORD '${KEYCLOAK_DB_PASSWORD}';
  END IF;
END
\$\$;

-- Create KEYCLOAK database if it doesn't exist
SELECT 'CREATE DATABASE ${KEYCLOAK_DB_NAME} OWNER ${KEYCLOAK_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${KEYCLOAK_DB_NAME}')\gexec

-- Grant all privileges on Keycloak database to Keycloak user
GRANT ALL PRIVILEGES ON DATABASE ${KEYCLOAK_DB_NAME} TO ${KEYCLOAK_DB_USER};
EOF

# Grant schema privileges for Keycloak database
docker exec -i "${CONTAINER_NAME}" psql -U "${POSTGRES_ADMIN_USER}" -d "${KEYCLOAK_DB_NAME}" <<EOF
-- Grant schema privileges
GRANT ALL ON SCHEMA public TO ${KEYCLOAK_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${KEYCLOAK_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${KEYCLOAK_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${KEYCLOAK_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${KEYCLOAK_DB_USER};
EOF

log_success "Keycloak database and user created"

# ============================================================================
# Configure PostgreSQL for Remote Connections (Kubernetes Pods)
# ============================================================================

log_info "Configuring PostgreSQL for Kubernetes Pod connections..."

# Update pg_hba.conf to allow connections from Kubernetes pods
# Using docker exec to modify pg_hba.conf inside the container
docker exec -i "${CONTAINER_NAME}" bash <<'BASH_SCRIPT'
set -e

# Backup pg_hba.conf
if [ ! -f /var/lib/postgresql/data/pgdata/pg_hba.conf.backup ]; then
  cp /var/lib/postgresql/data/pgdata/pg_hba.conf /var/lib/postgresql/data/pgdata/pg_hba.conf.backup
fi

# Check if rules already exist to avoid duplicates
if ! grep -q "# AIWB Pluggable Database Configuration" /var/lib/postgresql/data/pgdata/pg_hba.conf; then
  cat >> /var/lib/postgresql/data/pgdata/pg_hba.conf <<'EOF'

# AIWB Pluggable Database Configuration - Added by db_postgresql_container.sh
# Allow password authentication for AIWB and Keycloak users from any host
# This allows Kubernetes pods to connect to the PostgreSQL container
host    all              all              0.0.0.0/0       scram-sha-256
host    all              all              ::/0            scram-sha-256
EOF
  echo "Updated pg_hba.conf to allow remote connections"
fi
BASH_SCRIPT

log_success "PostgreSQL configuration updated"

# Reload PostgreSQL configuration
log_info "Reloading PostgreSQL configuration..."
docker exec "${CONTAINER_NAME}" psql -U "${POSTGRES_ADMIN_USER}" -c "SELECT pg_reload_conf();" >/dev/null
log_success "Configuration reloaded"

# ============================================================================
# Verify Setup
# ============================================================================

log_info "Verifying AIWB user can connect..."
if docker exec -e PGPASSWORD="${AIWB_DB_PASSWORD}" "${CONTAINER_NAME}" psql -U "${AIWB_DB_USER}" -d "${AIWB_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
  log_success "AIWB user can connect successfully"
else
  log_error "AIWB user cannot connect. Please check the configuration."
fi

log_info "Verifying Keycloak user can connect..."
if docker exec -e PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" "${CONTAINER_NAME}" psql -U "${KEYCLOAK_DB_USER}" -d "${KEYCLOAK_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
  log_success "Keycloak user can connect successfully"
else
  log_error "Keycloak user cannot connect. Please check the configuration."
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================================================="
echo "Pluggable Database Setup Complete"
echo "=========================================================================="
echo ""
echo "Container Information:"
echo "  Container Name: ${CONTAINER_NAME}"
echo "  PostgreSQL Version: ${POSTGRES_VERSION}"
echo "  Status: $(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}")"
echo ""
echo "Database Configuration:"
echo "  Host (WSL): localhost"
echo "  Host (K8s pods): ${K8S_DB_HOST}"
echo "  Port: ${POSTGRES_PORT}"
echo ""
echo "AIWB Database:"
echo "  Database: ${AIWB_DB_NAME}"
echo "  Username: ${AIWB_DB_USER}"
echo "  Password: ${AIWB_DB_PASSWORD}"
echo ""
echo "Keycloak Database:"
echo "  Database: ${KEYCLOAK_DB_NAME}"
echo "  Username: ${KEYCLOAK_DB_USER}"
echo "  Password: ${KEYCLOAK_DB_PASSWORD}"
echo ""
echo "Connection Strings:"
echo "  From WSL:"
echo "    AIWB:     postgresql://${AIWB_DB_USER}:${AIWB_DB_PASSWORD}@localhost:${POSTGRES_PORT}/${AIWB_DB_NAME}"
echo "    Keycloak: postgresql://${KEYCLOAK_DB_USER}:${KEYCLOAK_DB_PASSWORD}@localhost:${POSTGRES_PORT}/${KEYCLOAK_DB_NAME}"
echo ""
echo "  From Kubernetes Pods:"
echo "    AIWB:     postgresql://${AIWB_DB_USER}:${AIWB_DB_PASSWORD}@${K8S_DB_HOST}:${POSTGRES_PORT}/${AIWB_DB_NAME}"
echo "    Keycloak: postgresql://${KEYCLOAK_DB_USER}:${KEYCLOAK_DB_PASSWORD}@${K8S_DB_HOST}:${POSTGRES_PORT}/${KEYCLOAK_DB_NAME}"
echo ""
echo "Container Management:"
echo "  View logs:     docker logs ${CONTAINER_NAME}"
echo "  Stop:          docker stop ${CONTAINER_NAME}"
echo "  Start:         docker start ${CONTAINER_NAME}"
echo "  Restart:       docker restart ${CONTAINER_NAME}"
echo "  Connect:       docker exec -it ${CONTAINER_NAME} psql -U ${POSTGRES_ADMIN_USER}"
echo "  Remove:        docker rm -f ${CONTAINER_NAME}"
echo ""
echo "Next Steps:"
echo "  1. Update your Kubernetes secrets with these database credentials"
echo "  2. Use '${K8S_DB_HOST}' as the host in K8s pod connection strings"
echo "  3. Configure AIWB and Keycloak to use this external database"
echo "  4. See db.md for manual configuration options and troubleshooting"
echo ""
echo "=========================================================================="
