#!/bin/bash

# BYO Database Setup Script for AIWB
# This script sets up PostgreSQL users and databases required for AIWB and Keycloak
# Prerequisites: PostgreSQL installed and running (e.g., via `brew install postgresql`)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Database connection settings
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"

# Application database settings
AIWB_DB_NAME="aiwb"
AIWB_DB_USER="aiwb_user"
AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"

KEYCLOAK_DB_NAME="keycloak"
KEYCLOAK_DB_USER="keycloak"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"

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
# PostgreSQL Configuration Check
# ============================================================================

log_info "Checking PostgreSQL server status..."
if ! pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
  log_error "PostgreSQL server is not ready at ${POSTGRES_HOST}:${POSTGRES_PORT}"
  log_error "Start PostgreSQL first: brew services start postgresql"
  exit 1
fi
log_success "PostgreSQL server is ready"

# Auto-detect PostgreSQL admin user if not specified
if [ "${POSTGRES_ADMIN_USER}" = "postgres" ]; then
  # Check if postgres role exists
  if ! psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    log_info "Role 'postgres' does not exist. Checking for system user..."
    CURRENT_USER=$(whoami)
    if psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${CURRENT_USER}" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
      log_info "Using system user '${CURRENT_USER}' as PostgreSQL admin"
      POSTGRES_ADMIN_USER="${CURRENT_USER}"

      # Create postgres role for convenience
      log_info "Creating 'postgres' superuser role for standard compatibility..."
      psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${CURRENT_USER}" -d postgres <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD 'postgres';
    RAISE NOTICE 'Created postgres superuser role';
  END IF;
END
\$\$;
EOF
      log_success "postgres role created"
      POSTGRES_ADMIN_USER="postgres"
    else
      log_error "Could not connect with user 'postgres' or '${CURRENT_USER}'"
      log_error "Set POSTGRES_ADMIN_USER environment variable to your PostgreSQL superuser"
      exit 1
    fi
  fi
fi

# ============================================================================
# Create AIWB Database and User
# ============================================================================

log_info "Creating AIWB database and user..."

psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_ADMIN_USER}" -d postgres <<EOF
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
psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_ADMIN_USER}" -d "${AIWB_DB_NAME}" <<EOF
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

psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_ADMIN_USER}" -d postgres <<EOF
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
psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_ADMIN_USER}" -d "${KEYCLOAK_DB_NAME}" <<EOF
-- Grant schema privileges
GRANT ALL ON SCHEMA public TO ${KEYCLOAK_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${KEYCLOAK_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${KEYCLOAK_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${KEYCLOAK_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${KEYCLOAK_DB_USER};
EOF

log_success "Keycloak database and user created"

# ============================================================================
# Configure PostgreSQL for Remote Connections
# ============================================================================

log_info "Configuring PostgreSQL for remote connections..."

# Get PostgreSQL config directory
PG_CONFIG_DIR=$(psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_ADMIN_USER}" -d postgres -t -c "SHOW config_file" | xargs dirname)

if [ -z "${PG_CONFIG_DIR}" ]; then
  log_error "Could not determine PostgreSQL configuration directory"
  exit 1
fi

log_info "PostgreSQL config directory: ${PG_CONFIG_DIR}"

# Backup configuration files
if [ ! -f "${PG_CONFIG_DIR}/pg_hba.conf.backup" ]; then
  cp "${PG_CONFIG_DIR}/pg_hba.conf" "${PG_CONFIG_DIR}/pg_hba.conf.backup"
  log_info "Backed up pg_hba.conf"
fi

if [ ! -f "${PG_CONFIG_DIR}/postgresql.conf.backup" ]; then
  cp "${PG_CONFIG_DIR}/postgresql.conf" "${PG_CONFIG_DIR}/postgresql.conf.backup"
  log_info "Backed up postgresql.conf"
fi

# Update postgresql.conf to listen on all addresses (0.0.0.0)
if ! grep -q "listen_addresses = '\*'" "${PG_CONFIG_DIR}/postgresql.conf"; then
  echo "" >> "${PG_CONFIG_DIR}/postgresql.conf"
  echo "# Added by db_postgresql_homebrew.sh for remote connections (required for Kubernetes pods)" >> "${PG_CONFIG_DIR}/postgresql.conf"
  echo "listen_addresses = '*'  # Listen on all interfaces (0.0.0.0)" >> "${PG_CONFIG_DIR}/postgresql.conf"
  log_info "Updated postgresql.conf to listen on all addresses (0.0.0.0)"
else
  log_success "PostgreSQL already configured to listen on all addresses"
fi

# Update pg_hba.conf to allow password authentication from remote hosts
# Check if rules already exist to avoid duplicates
if ! grep -q "# AIWB BYO Database Configuration" "${PG_CONFIG_DIR}/pg_hba.conf"; then
  cat >> "${PG_CONFIG_DIR}/pg_hba.conf" <<EOF

# AIWB BYO Database Configuration - Added by db_postgresql_homebrew.sh
# Allow password authentication for AIWB and Keycloak users from any host
# For production, replace 0.0.0.0/0 with specific IP ranges or CIDR blocks
host    ${AIWB_DB_NAME}      ${AIWB_DB_USER}      0.0.0.0/0       scram-sha-256
host    ${KEYCLOAK_DB_NAME}  ${KEYCLOAK_DB_USER}  0.0.0.0/0       scram-sha-256
# IPv6 support
host    ${AIWB_DB_NAME}      ${AIWB_DB_USER}      ::/0            scram-sha-256
host    ${KEYCLOAK_DB_NAME}  ${KEYCLOAK_DB_USER}  ::/0            scram-sha-256
EOF
  log_info "Updated pg_hba.conf to allow remote password authentication"
fi

log_success "PostgreSQL configuration updated"

# ============================================================================
# Restart PostgreSQL
# ============================================================================

log_info "Restarting PostgreSQL to apply configuration changes..."
if command -v brew >/dev/null 2>&1; then
  brew services restart postgresql || {
    log_error "Failed to restart PostgreSQL. Please restart manually:"
    log_error "  brew services restart postgresql"
    exit 1
  }
  log_success "PostgreSQL restarted successfully"
else
  log_info "Please restart PostgreSQL manually to apply configuration changes"
fi

# ============================================================================
# Verify Setup
# ============================================================================

log_info "Waiting for PostgreSQL to be ready after restart..."
sleep 3

if pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
  log_success "PostgreSQL is ready"
else
  log_error "PostgreSQL is not ready. Please check the service status."
  exit 1
fi

log_info "Verifying AIWB user can connect..."
if PGPASSWORD="${AIWB_DB_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${AIWB_DB_USER}" -d "${AIWB_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
  log_success "AIWB user can connect successfully"
else
  log_error "AIWB user cannot connect. Please check the configuration."
fi

log_info "Verifying Keycloak user can connect..."
if PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${KEYCLOAK_DB_USER}" -d "${KEYCLOAK_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
  log_success "Keycloak user can connect successfully"
else
  log_error "Keycloak user cannot connect. Please check the configuration."
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================================================="
echo "BYO Database Setup Complete"
echo "=========================================================================="
echo ""
echo "Database Configuration:"
echo "  Host: ${POSTGRES_HOST}"
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
echo "  AIWB:     postgresql://${AIWB_DB_USER}:${AIWB_DB_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${AIWB_DB_NAME}"
echo "  Keycloak: postgresql://${KEYCLOAK_DB_USER}:${KEYCLOAK_DB_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${KEYCLOAK_DB_NAME}"
echo ""
echo "Next Steps:"
echo "  1. Update your Kubernetes secrets with these database credentials"
echo "  2. Configure AIWB and Keycloak to use this external database"
echo "  3. See db.md for manual configuration options and troubleshooting"
echo ""
echo "=========================================================================="