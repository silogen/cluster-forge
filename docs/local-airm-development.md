# Local AIRM Development Against Kind Cluster

This guide explains how to run the AIRM UI and API locally on your machine while connected to services running in the Kind cluster.

> **Note**: Throughout this guide:
> - `<cluster-forge-path>` refers to your local cluster-forge repository path
> - `<silogen-core-path>` refers to your local silogen-core repository path

## Overview

Instead of running everything in containers, you can:
- Run AIRM API locally with `uv run -m app` (hot reload)
- Run AIRM UI locally with `pnpm dev` (hot reload)
- Connect to PostgreSQL, Keycloak, RabbitMQ, MinIO in the Kind cluster via port-forwarding

This provides a much faster development workflow with instant code changes.

## Prerequisites

1. **Kind cluster running with AIRM deployed:**
   ```bash
   cd <cluster-forge-path>
   kind delete cluster --name cluster-forge-local
   kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml
   ./scripts/bootstrap-kind-cluster.sh localhost.local
   ```

2. **AIRM source code:**
   ```bash
   cd <silogen-core-path>/services/airm
   ```

3. **Development tools:**
   - Python with `uv` (for API)
   - Node.js with `pnpm` (for UI)

## Step 1: Port-Forward Cluster Services and Generate Config Files

Run the port-forward helper script in a dedicated terminal:

```bash
cd <cluster-forge-path>
./scripts/connect-kind-cluster.sh
```

This script will:
- **Configure Keycloak authentication**:
  - Resets devuser password to non-temporary
  - Configures kubectl OIDC contexts (optional)
  - Keycloak accessible via NodePort at `localhost:8080`
- **Port-forward cluster services**:
  - PostgreSQL: `localhost:5432`
  - RabbitMQ: `localhost:5672` (AMQP), `localhost:15672` (Management UI)
  - MinIO: `localhost:9000`
  - Cluster Auth: `localhost:48012`
- **Automatically generate `.env` files** with credentials from the cluster:
  - `<silogen-core-path>/services/airm/api/.env`
  - `<silogen-core-path>/services/airm/ui/.env.local`
- **Monitor cluster resources**: Interactive display of CPU, memory, disk usage, and service status

Keep this terminal running while developing.

> **Note**: The script automatically retrieves all credentials from the cluster and populates the `.env` files. You don't need to manually configure anything!

## Step 2: Run AIRM API

In a new terminal:

```bash
cd <silogen-core-path>/services/airm/api

# Install dependencies (first time only)
uv sync

# Run with hot reload
uv run -m app

# API will be available at http://localhost:8001
```

The API will automatically reload when you change Python files.

## Step 3: Run AIRM UI

In another new terminal:

```bash
cd <silogen-core-path>/services/airm/ui

# Install dependencies (first time only)
pnpm install

# Run with hot reload
pnpm dev

# UI will be available at http://localhost:8010
```

The UI will automatically reload when you change TypeScript/React files.

## Step 4: Access and Test

1. **Open AIRM UI**: http://localhost:8010
2. **Login**: Use `devuser@localhost.local` / `password`
3. **API Docs**: http://localhost:8001/docs (FastAPI Swagger UI)

## Tips

### Database Access

Connect directly to PostgreSQL:

```bash
PGPASSWORD=$DB_PASSWORD psql -h localhost -p 5432 -U $DB_USER -d airm
```

### RabbitMQ Management UI

Access at: http://localhost:15672
- Username: (from RABBITMQ_ADMIN_USER)
- Password: (from RABBITMQ_ADMIN_PASSWORD)

### MinIO Console

Access at: http://localhost:9000
- Username: `minioadmin`
- Password: `minioadmin`

### Debugging

**API Logs**: Check the terminal where `uv run -m app` is running

**UI Logs**: Check the terminal where `pnpm dev` is running, and browser console

**Database Queries**: Enable SQL logging in the API by setting `SQLALCHEMY_ECHO=true` in `.env`

### Hot Reload

- **API**: Changes to Python files reload automatically
- **UI**: Changes to TypeScript/React files reload automatically in browser
- **Database**: Use migrations or direct SQL - changes persist in cluster

## Cleanup

When done developing:

1. Stop UI: Ctrl+C in the UI terminal
2. Stop API: Ctrl+C in the API terminal
3. Stop port-forwards: Ctrl+C in the port-forward terminal

The Kind cluster continues running. To stop it completely:

```bash
kind delete cluster --name cluster-forge-local
```

## Troubleshooting

### Port Already in Use

If port-forwarding fails, kill existing processes:

```bash
# Find and kill process using port 5432 (example)
lsof -ti:5432 | xargs kill -9
```

### Database Connection Failed

Verify the port-forward is running and credentials are correct:

```bash
kubectl get secret airm-cnpg-user -n airm -o yaml
```

### Keycloak Auth Failed

Check Keycloak is accessible:

```bash
curl http://localhost:8080/realms/airm/.well-known/openid-configuration
```

If you get connection refused errors, ensure:
1. The connect script is running (Keycloak uses NodePort on port 8080)
2. Node.js is using IPv4 (check `NODE_OPTIONS` in `.env.local` includes `--dns-result-order=ipv4first`)

### API Can't Connect to Services

Ensure all port-forwards are running:

```bash
ps aux | grep "kubectl port-forward"
```

## Advantages of This Setup

✅ **Fast iteration**: Changes reload instantly without rebuilding containers
✅ **Easy debugging**: Use IDE debuggers, print statements, browser DevTools
✅ **Realistic environment**: Services (DB, Keycloak, RabbitMQ) match production
✅ **Resource efficient**: Only run what you're actively developing locally
✅ **Persistent data**: Database and other state persist in the cluster
