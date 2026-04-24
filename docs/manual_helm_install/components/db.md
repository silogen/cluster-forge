# Pluggable PostgreSQL Compatible Database

This guide describes how to replace the ClusterForge-managed PostgreSQL database with your own external PostgreSQL instance.

## Overview

ClusterForge provisions your Kubernetes cluster with AIWB and Keycloak already deployed and connected to an in-cluster PostgreSQL database managed by CloudNativePG (CNPG). The AIWB and Keycloak deployments are pre-configured with hardcoded database usernames that match this CNPG installation.

These instructions walk you through:

1. Setting up your own external PostgreSQL server with the required databases and users
2. Removing the CNPG cluster resources from the `aiwb` and `keycloak` namespaces
3. Patching the Kubernetes secrets and deployments that ClusterForge created so that AIWB and Keycloak connect to your database instead

## Prerequisites

1. **PostgreSQL 12 or later** is installed and running
2. **kubectl** is installed and configured to access your ClusterForge cluster
3. **Network connectivity** between your Kubernetes cluster and your PostgreSQL server

## Step 1: Configure PostgreSQL

### Network access

PostgreSQL must accept remote connections from Kubernetes pods.

Edit `postgresql.conf`:

```conf
listen_addresses = '*'
```

Edit `pg_hba.conf` to allow connections from your cluster and restart PostgreSQL to apply changes:

```conf
host    aiwb      aiwb_user      0.0.0.0/0       scram-sha-256
host    keycloak  keycloak       0.0.0.0/0       scram-sha-256
```

> **Security**: For production, replace `0.0.0.0/0` with your Kubernetes cluster's IP range (e.g. `10.42.0.0/16`).

Verify PostgreSQL is listening on all interfaces:

```bash
psql -U postgres -c "SHOW listen_addresses"
# Expected output: * or 0.0.0.0
```

### Create databases and users

Connect to PostgreSQL and run:

```sql
-- Create users
CREATE USER aiwb_user WITH PASSWORD 'your_secure_password';
CREATE USER keycloak WITH PASSWORD 'your_secure_password';

-- Create databases
CREATE DATABASE aiwb OWNER aiwb_user;
CREATE DATABASE keycloak OWNER keycloak;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE aiwb TO aiwb_user;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
```

Then grant schema-level privileges:

```sql
-- AIWB database
\c aiwb
GRANT ALL ON SCHEMA public TO aiwb_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO aiwb_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO aiwb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO aiwb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO aiwb_user;

-- Keycloak database
\c keycloak
GRANT ALL ON SCHEMA public TO keycloak;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO keycloak;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO keycloak;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO keycloak;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO keycloak;
```

## Step 2: Set your configuration variables

Set these shell variables before running the kubectl commands below. Replace all placeholder values with your actual database details.

```bash
POSTGRES_HOST="your-db-host"        # e.g. host.docker.internal or db.example.com
POSTGRES_PORT="5432"

AIWB_DB_NAME="aiwb"
AIWB_DB_USER="aiwb_user"
AIWB_DB_PASSWORD="your_aiwb_password"

KEYCLOAK_DB_NAME="keycloak"
KEYCLOAK_DB_USER="keycloak"
KEYCLOAK_DB_PASSWORD="your_keycloak_password"
```

## Step 3: Remove in-cluster CNPG clusters

> **WARNING — DATA LOSS**: This step permanently deletes the in-cluster PostgreSQL clusters and all data stored in them. Back up any data you need before proceeding.

```bash
kubectl delete cluster -n aiwb aiwb-infra-cnpg-cnpg --ignore-not-found
kubectl delete cluster -n keycloak keycloak-cnpg --ignore-not-found
```

Wait for the database pods to terminate:

```bash
kubectl wait --for=delete pod \
  -l "cnpg.io/cluster=aiwb-infra-cnpg-cnpg" \
  -n aiwb \
  --timeout=120s 2>/dev/null || true

kubectl wait --for=delete pod \
  -l "cnpg.io/cluster=keycloak-cnpg" \
  -n keycloak \
  --timeout=120s 2>/dev/null || true
```

## Step 4: Update Kubernetes secrets

Kubernetes secrets store credentials as base64-encoded strings. Encode your credentials:

```bash
AIWB_USER_B64=$(echo -n "$AIWB_DB_USER" | base64 -w 0)
AIWB_PASS_B64=$(echo -n "$AIWB_DB_PASSWORD" | base64 -w 0)
KEYCLOAK_USER_B64=$(echo -n "$KEYCLOAK_DB_USER" | base64 -w 0)
KEYCLOAK_PASS_B64=$(echo -n "$KEYCLOAK_DB_PASSWORD" | base64 -w 0)
```

> **macOS**: Use `base64` without the `-w 0` flag.

### Update AIWB secret

```bash
kubectl patch secret aiwb-cnpg-user -n aiwb --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/username\", \"value\": \"${AIWB_USER_B64}\"},
  {\"op\": \"replace\", \"path\": \"/data/password\", \"value\": \"${AIWB_PASS_B64}\"}
]"
```

### Update Keycloak secret

```bash
kubectl patch secret keycloak-cnpg-user -n keycloak --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/data/username\", \"value\": \"${KEYCLOAK_USER_B64}\"},
  {\"op\": \"replace\", \"path\": \"/data/password\", \"value\": \"${KEYCLOAK_PASS_B64}\"}
]"
```

## Step 5: Update AIWB deployment

### Set database environment variables

```bash
kubectl set env deployment/aiwb-api -n aiwb \
  DATABASE_HOST="${POSTGRES_HOST}" \
  DATABASE_PORT="${POSTGRES_PORT}" \
  DATABASE_NAME="${AIWB_DB_NAME}" \
  DATABASE_USER="${AIWB_DB_USER}"
```

### Patch the `wait-for-db` init container

The `wait-for-db` init container polls the database host until PostgreSQL is accepting connections. Update it to point to your external host:

```bash
kubectl patch deployment aiwb-api -n aiwb --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/0/command/2\",
    \"value\": \"until pg_isready -h \\\"${POSTGRES_HOST}\\\" -p ${POSTGRES_PORT} -U ${AIWB_DB_USER}; do\\n  echo \\\"Waiting for database...\\\"\\n  sleep 2\\ndone\\necho \\\"Database is ready!\\\"\\n\"
  }
]"
```

### Patch the `liquibase-migrate` init container

The `liquibase-migrate` init container runs schema migrations. Update its JDBC connection URL:

```bash
kubectl patch deployment aiwb-api -n aiwb --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/2/command/1\",
    \"value\": \"--url=jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${AIWB_DB_NAME}\"
  }
]"
```

## Step 6: Update Keycloak deployment

```bash
kubectl set env deployment/keycloak -n keycloak \
  KC_DB_URL_HOST="${POSTGRES_HOST}" \
  KC_DB_URL_PORT="${POSTGRES_PORT}" \
  KC_DB_URL_DATABASE="${KEYCLOAK_DB_NAME}"
```

## Step 7: Restart deployments and wait for rollouts

Apply all changes by restarting both deployments:

```bash
kubectl rollout restart deployment/aiwb-api -n aiwb
kubectl rollout restart deployment/keycloak -n keycloak
```

Wait for the rollouts to complete (timeout 5 minutes each):

```bash
kubectl rollout status deployment/aiwb-api -n aiwb --timeout=300s
kubectl rollout status deployment/keycloak -n keycloak --timeout=300s
```

## Step 8: Verify the configuration

### Check pod status

```bash
kubectl get pods -n aiwb
kubectl get pods -n keycloak
```

All pods should reach `Running` state.

### Confirm environment variables

```bash
# AIWB
kubectl get deployment aiwb-api -n aiwb \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# Keycloak
kubectl get deployment keycloak -n keycloak \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
```

### Confirm secrets

```bash
kubectl get secret aiwb-cnpg-user -n aiwb \
  -o jsonpath='{.data.username}' | base64 -d

kubectl get secret keycloak-cnpg-user -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d
```

### Check init container logs

```bash
# Confirm database was reachable before pod started
kubectl logs -n aiwb deployment/aiwb-api -c wait-for-db

# Confirm schema migrations ran successfully
kubectl logs -n aiwb deployment/aiwb-api -c liquibase-migrate
```

### Test connectivity from outside Kubernetes

```bash
PGPASSWORD="$AIWB_DB_PASSWORD" psql -h "$POSTGRES_HOST" -U "$AIWB_DB_USER" -d "$AIWB_DB_NAME" -c "SELECT 1"
PGPASSWORD="$KEYCLOAK_DB_PASSWORD" psql -h "$POSTGRES_HOST" -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" -c "SELECT 1"
```

