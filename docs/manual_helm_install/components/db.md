# Pluggable PostgreSQL Database

Cluster Forge can be installed against an external PostgreSQL server instead
of the in-cluster CloudNativePG (CNPG) Clusters. In this mode `install_base.sh`
skips the cnpg-operator install, skips the Cluster CRs in the AIWB and
Keycloak charts, and creates the user Secrets that AIWB and Keycloak read at
startup directly from environment variables.

## Prerequisites

- PostgreSQL 12 or later, reachable from the cluster
- Two databases pre-created with their own users:
  - `aiwb` owned by `aiwb_user`
  - `keycloak` owned by `keycloak`
- Each user has full privileges on its database (schema `public`, tables,
  sequences, default privileges)

Example provisioning SQL:

```sql
CREATE USER aiwb_user WITH PASSWORD 'your_secure_password';
CREATE USER keycloak  WITH PASSWORD 'your_secure_password';

CREATE DATABASE aiwb     OWNER aiwb_user;
CREATE DATABASE keycloak OWNER keycloak;

\c aiwb
GRANT ALL ON SCHEMA public TO aiwb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO aiwb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO aiwb_user;

\c keycloak
GRANT ALL ON SCHEMA public TO keycloak;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO keycloak;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO keycloak;
```

PostgreSQL must accept remote connections from the cluster — set
`listen_addresses = '*'` in `postgresql.conf` and add `host` rules to
`pg_hba.conf` for your cluster's pod CIDR.

## Install

1. Set environment variables:

   ```bash
   export POSTGRES_HOST=your-db-host       # e.g. host.docker.internal
   export POSTGRES_PORT=5432

   export AIWB_DB_NAME=aiwb
   export AIWB_DB_USER=aiwb_user
   export AIWB_DB_PASSWORD=your_aiwb_password

   export KEYCLOAK_DB_NAME=keycloak
   export KEYCLOAK_DB_USER=keycloak
   export KEYCLOAK_DB_PASSWORD=your_keycloak_password
   ```

2. Run pluggable.sh (which sets `PLUGGABLE_DB=true` and calls
   `install_base.sh`):

   ```bash
   ./scripts/pluggable.sh <DOMAIN>
   ```

## What install_base.sh does in PLUGGABLE_DB=true mode

- Skips installing the cnpg-operator
- Skips the CNPG `Cluster` CRs in the AIWB and Keycloak charts (renders the
  charts with `cnpg.enabled=false`)
- Skips creating the CNPG superuser / user Secrets (`aiwb-cnpg-superuser`,
  `aiwb-cnpg-user`, `keycloak-cnpg-superuser`, `keycloak-cnpg-user`) — none
  of them are needed when the in-cluster CNPG cluster is not running
- Creates the user Secrets that AIWB and Keycloak read at startup
  (`${AIWB_DB_SECRET_NAME}`, `${KEYCLOAK_DB_SECRET_NAME}`) from
  `${AIWB_DB_USER}` / `${AIWB_DB_PASSWORD}` and `${KEYCLOAK_DB_USER}` /
  `${KEYCLOAK_DB_PASSWORD}`
- Renders the AIWB and Keycloak charts with `--set postgresql.host`,
  `postgresql.port`, `postgresql.dbName`, and `postgresql.userSecretName`
  pointing at the external server

## Verify

```bash
kubectl get pods -n aiwb
kubectl get pods -n keycloak

# Confirm AIWB read the right host
kubectl logs -n aiwb deployment/aiwb-api -c wait-for-db

# Test connectivity from outside the cluster
PGPASSWORD="$AIWB_DB_PASSWORD"     psql -h "$POSTGRES_HOST" -U "$AIWB_DB_USER"     -d "$AIWB_DB_NAME"     -c "SELECT 1"
PGPASSWORD="$KEYCLOAK_DB_PASSWORD" psql -h "$POSTGRES_HOST" -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" -c "SELECT 1"
```

## Limitations

- **No migration path**: `PLUGGABLE_DB=true` is for fresh installs. There is
  no built-in flow to move data from a previous in-cluster CNPG Cluster to
  an external Postgres.
- **Single Postgres instance assumed**: AIWB and Keycloak both connect to
  the same `${POSTGRES_HOST}:${POSTGRES_PORT}`. Use separate hosts/users for
  isolation if required by your environment, but both databases must be
  reachable on the same endpoint.
- **No connection pooler default**: install_base.sh does not deploy PgBouncer
  or similar — connect AIWB / Keycloak through your own pooler if the
  external Postgres needs one.
- **Cosmetic log noise**: AIWB's `wait-for-db` init container hardcodes
  `pg_isready -U postgres` (see `EXTERNAL_FIXES.md`). The check still
  succeeds against the external Postgres, but the pod log will print
  `FATAL: role "postgres" does not exist` lines until the external host has
  a `postgres` role or until the upstream chart is fixed.
