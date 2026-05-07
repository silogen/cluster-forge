# Database (PostgreSQL)

AIWB and Keycloak both need PostgreSQL. Two deployment modes are supported:

- **In-cluster mode (default)** — install the CloudNativePG (CNPG) operator
  and provision in-cluster `Cluster` CRs for AIWB and Keycloak.
- **Pluggable mode** — point AIWB / Keycloak at a user-supplied external
  PostgreSQL endpoint, with no in-cluster CNPG components.

In both modes the credentials AIWB and Keycloak read at startup live in
Kubernetes Secrets that you create with `kubectl create secret generic`. No
static `secrets-*.yaml` file is required.

These instructions assume you have the cluster-forge sources available
locally and that `SOURCES_DIR` points at the `sources/` directory:

```bash
git clone --depth 1 https://github.com/silogen/cluster-forge.git /tmp/cluster-forge
export SOURCES_DIR=/tmp/cluster-forge/sources
```

The `aiwb` and `keycloak` namespaces must exist before creating Secrets in
them:

```bash
kubectl create namespace aiwb     --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
```

## In-cluster mode (default)

### Environment variables

Set these before running the commands below. Defaults are placeholders;
replace for any non-dev install.

| Variable | Default | Used for |
|---|---|---|
| `AIWB_DB_USER` | `aiwb_user` | `aiwb-cnpg-user.username` (AIWB app login) |
| `AIWB_DB_PASSWORD` | `examplepassword` | `aiwb-cnpg-user.password` |
| `AIWB_CNPG_SUPERUSER_USER` | `placeholder` | `aiwb-cnpg-superuser.username` (CNPG bootstrap) |
| `AIWB_CNPG_SUPERUSER_PASSWORD` | `placeholder` | `aiwb-cnpg-superuser.password` |
| `KEYCLOAK_DB_USER` | `keycloak` | `keycloak-cnpg-user.username` |
| `KEYCLOAK_DB_PASSWORD` | `examplepassword` | `keycloak-cnpg-user.password` |
| `KEYCLOAK_CNPG_SUPERUSER_USER` | `placeholder` | `keycloak-cnpg-superuser.username` |
| `KEYCLOAK_CNPG_SUPERUSER_PASSWORD` | `placeholder` | `keycloak-cnpg-superuser.password` |
| `DEFAULT_STORAGE_CLASS_NAME` | `default` | PVC storage class for CNPG volumes |
| `CNPG_INSTANCES` | `1` | Number of replicas in each CNPG `Cluster` |

The `*_CNPG_SUPERUSER_*` values populate the Secrets the CNPG `Cluster` spec
references at bootstrap; application pods do not consume them.

### 1. Install the CNPG operator

```bash
kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f -

helm template cnpg-operator ${SOURCES_DIR}/cnpg-operator/0.26.0 \
  --namespace cnpg-system | kubectl apply --server-side -f -

kubectl wait --for=condition=available --timeout=120s \
  deployment/cnpg-operator-cloudnative-pg -n cnpg-system
```

### 2. Create CNPG credential Secrets

```bash
kubectl create secret generic aiwb-cnpg-superuser -n aiwb \
  --from-literal=username="${AIWB_CNPG_SUPERUSER_USER}" \
  --from-literal=password="${AIWB_CNPG_SUPERUSER_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic aiwb-cnpg-user -n aiwb \
  --from-literal=username="${AIWB_DB_USER}" \
  --from-literal=password="${AIWB_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic keycloak-cnpg-superuser -n keycloak \
  --from-literal=username="${KEYCLOAK_CNPG_SUPERUSER_USER}" \
  --from-literal=password="${KEYCLOAK_CNPG_SUPERUSER_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic keycloak-cnpg-user -n keycloak \
  --from-literal=username="${KEYCLOAK_DB_USER}" \
  --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Render the AIWB CNPG `Cluster`

```bash
helm template aiwb-infra-cnpg ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0 \
  -f ${SOURCES_DIR}/eai-infra/aiwb-cnpg/0.1.0/values.yaml \
  --set instances=${CNPG_INSTANCES} \
  --set username=${AIWB_DB_USER} \
  --set storage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --set walStorage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --namespace aiwb | kubectl apply --server-side -f -
```

Wait for the cluster to come up:

```bash
until kubectl get cluster -n aiwb -o jsonpath='{.items[0].status.phase}' \
    2>/dev/null | grep -q "Cluster in healthy state"; do
  echo "  Still waiting for AIWB PostgreSQL cluster..."
  sleep 5
done
```

### 4. Chart `--set` flags for Keycloak and AIWB

When rendering the Keycloak chart in this mode, pass:

```text
--set cnpg.enabled=true
--set cnpg.instances=${CNPG_INSTANCES}
--set cnpg.storage.storageClassName=${DEFAULT_STORAGE_CLASS_NAME}
--set postgresql.username=${KEYCLOAK_DB_USER}
```

When rendering the AIWB chart, pass:

```text
--set postgresql.username=${AIWB_DB_USER}
```

Host, port, database, and user-secret name come from the chart defaults and
point at the in-cluster `aiwb-cnpg` and `keycloak-cnpg` Clusters.

### Verify

```bash
kubectl get cluster -n aiwb
kubectl get cluster -n keycloak
kubectl get pods    -n aiwb
kubectl get pods    -n keycloak
```

## Pluggable mode

External PostgreSQL reachable from the cluster, with two databases
pre-created. Use this to run AIWB and Keycloak against a managed Postgres or
a dev container instead of the in-cluster CNPG `Cluster`s.

### Prerequisites

- PostgreSQL 12 or later, reachable from the cluster
- Two databases pre-created with their own users:
  - `aiwb` owned by `aiwb_user`
  - `keycloak` owned by `keycloak`
- Each user has full privileges on its database (schema `public`, tables,
  sequences, default privileges)
- PostgreSQL configured to accept remote connections from the cluster:
  `listen_addresses = '*'` in `postgresql.conf` and `host` rules in
  `pg_hba.conf` covering the cluster's pod CIDR

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

### Environment variables

| Variable | Default | Used for |
|---|---|---|
| `POSTGRES_HOST` | `host.docker.internal` | External PG host |
| `POSTGRES_PORT` | `5432` | External PG port |
| `AIWB_DB_NAME` | `aiwb` | AIWB database name |
| `AIWB_DB_USER` | `aiwb_user` | `aiwb-db-user.username` |
| `AIWB_DB_PASSWORD` | `examplepassword` | `aiwb-db-user.password` |
| `KEYCLOAK_DB_NAME` | `keycloak` | Keycloak database name |
| `KEYCLOAK_DB_USER` | `keycloak` | `keycloak-db-user.username` |
| `KEYCLOAK_DB_PASSWORD` | `examplepassword` | `keycloak-db-user.password` |

The Secret names `aiwb-db-user` / `keycloak-db-user` are referenced via the
chart `--set postgresql.userSecretName=...` flags below.

### 1. Skip the CNPG operator

In pluggable mode the CNPG operator is not installed at all — neither the
`cnpg-system` namespace nor the operator deployment is needed.

### 2. Create user Secrets

```bash
kubectl create secret generic aiwb-db-user -n aiwb \
  --from-literal=username="${AIWB_DB_USER}" \
  --from-literal=password="${AIWB_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic keycloak-db-user -n keycloak \
  --from-literal=username="${KEYCLOAK_DB_USER}" \
  --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The four `*-cnpg-superuser` / `*-cnpg-user` Secrets from the in-cluster
mode are not needed — no in-cluster CNPG `Cluster` exists.

### 3. Chart `--set` flags for Keycloak and AIWB

When rendering the Keycloak chart in this mode, pass:

```text
--set cnpg.enabled=false
--set postgresql.host=${POSTGRES_HOST}
--set postgresql.port=${POSTGRES_PORT}
--set postgresql.database=${KEYCLOAK_DB_NAME}
--set postgresql.username=${KEYCLOAK_DB_USER}
--set postgresql.userSecretName=keycloak-db-user
```

When rendering the AIWB chart, pass:

```text
--set postgresql.host=${POSTGRES_HOST}
--set postgresql.port=${POSTGRES_PORT}
--set postgresql.database=${AIWB_DB_NAME}
--set postgresql.username=${AIWB_DB_USER}
--set postgresql.userSecretName=aiwb-db-user
```

### Verify

```bash
kubectl get pods -n aiwb
kubectl get pods -n keycloak

# Confirm AIWB read the right host
kubectl logs -n aiwb deployment/aiwb-api -c wait-for-db

# Test connectivity from outside the cluster
PGPASSWORD="$AIWB_DB_PASSWORD"     psql -h "$POSTGRES_HOST" -U "$AIWB_DB_USER"     -d "$AIWB_DB_NAME"     -c "SELECT 1"
PGPASSWORD="$KEYCLOAK_DB_PASSWORD" psql -h "$POSTGRES_HOST" -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" -c "SELECT 1"
```

### Limitations

- **No migration path**: pluggable mode is for fresh installs. There is no
  built-in flow to move data from a previous in-cluster CNPG Cluster to an
  external Postgres.
- **Single Postgres instance assumed**: AIWB and Keycloak both connect to
  the same `${POSTGRES_HOST}:${POSTGRES_PORT}`. Use separate hosts/users for
  isolation if required by your environment, but both databases must be
  reachable on the same endpoint.
- **No connection pooler**: the install path does not deploy PgBouncer or
  similar — connect AIWB / Keycloak through your own pooler if the external
  Postgres needs one.
- **Cosmetic log noise**: AIWB's `wait-for-db` init container hardcodes
  `pg_isready -U postgres` (see `EXTERNAL_FIXES.md`). The check still
  succeeds against the external Postgres, but the pod log will print
  `FATAL: role "postgres" does not exist` lines until the external host has
  a `postgres` role or until the upstream chart fix is merged and pulled in.
