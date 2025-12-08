#!/bin/bash
# Port-forward cluster services for local AIRM development
# This allows running AIRM UI and API locally while connected to the Kind cluster

# Get script directory and derive paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_FORGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLM_STUDIO_CORE_PATH="${LLM_STUDIO_CORE_PATH:-${CLUSTER_FORGE_ROOT}/../llm-studio-core}"

echo "🔌 Setting up port-forwards for local AIRM development..."
echo ""
echo "This will port-forward the following services:"
echo "  - PostgreSQL (5432)"
echo "  - Keycloak (8080)"
echo "  - RabbitMQ (5672, 15672)"
echo "  - MinIO (9000)"
echo "  - Cluster Auth (48012)"
echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Function to run port-forward in background and track PID
start_forward() {
    local display_name=$1
    local namespace=$2
    local service=$3
    local ports=$4
    
    echo "▶ Starting $display_name port-forward..."
    
    # Check if service exists
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        echo "   ⚠️  Service $service not found in namespace $namespace - skipping"
        return 1
    fi
    
    # Run port-forward in a loop to auto-restart on connection loss
    (
        while true; do
            kubectl port-forward -n "$namespace" "svc/$service" $ports 2>&1 | \
                grep -v "Handling connection" | \
                sed "s/^/[$display_name] /"
            echo "[$display_name] Connection lost, restarting in 2 seconds..."
            sleep 2
        done
    ) &
    local pid=$!
    echo "$pid" >> /tmp/airm-portforward-pids.txt
    sleep 1
    
    # Check if the process is still running
    if kill -0 $pid 2>/dev/null; then
        echo "   ✓ Started (PID: $pid)"
    else
        echo "   ⚠️  Failed to start"
        return 1
    fi
}

# Cleanup function
cleanup() {
    echo ""
    echo "🛑 Stopping all port-forwards..."
    if [ -f /tmp/airm-portforward-pids.txt ]; then
        while read pid; do
            # Kill the process and its children
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
        done < /tmp/airm-portforward-pids.txt
        rm /tmp/airm-portforward-pids.txt
    fi
    echo "✅ All port-forwards stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Clean up any previous PIDs file
rm -f /tmp/airm-portforward-pids.txt

# Start all port-forwards
start_forward "PostgreSQL" "airm" "airm-cnpg-rw" "5432:5432"
start_forward "Keycloak" "keycloak" "keycloak" "8080:8080"
start_forward "RabbitMQ" "airm" "airm-rabbitmq" "5672:5672 15672:15672"
start_forward "MinIO" "minio-tenant-default" "minio" "9000:80"
start_forward "Cluster Auth" "cluster-auth" "cluster-auth" "48012:8081"
# Optional: Prometheus (uncomment if otel-lgtm-stack is deployed)
# start_forward "Prometheus" "otel-lgtm-stack" "lgtm-stack" "9090:3000"

echo ""
echo "✅ All port-forwards started!"
echo ""

# Configure kubectl OIDC authentication for AIRM API testing
echo ""
echo "🔐 Configuring kubectl OIDC authentication..."

# Get the current context and user
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_USER="${CURRENT_CONTEXT}"
echo "   Current context: ${CURRENT_CONTEXT}"

# Get Keycloak admin client credentials
ADMIN_CLIENT_ID=$(kubectl get secret -n keycloak airm-realm-credentials -o jsonpath='{.data.ADMIN_CLIENT_ID}' 2>/dev/null | base64 -d)
ADMIN_CLIENT_SECRET=$(kubectl get secret -n keycloak airm-realm-credentials -o jsonpath='{.data.ADMIN_CLIENT_SECRET}' 2>/dev/null | base64 -d)

if [ -n "$ADMIN_CLIENT_ID" ] && [ -n "$ADMIN_CLIENT_SECRET" ]; then
    echo "   Found admin client ID: ${ADMIN_CLIENT_ID}"
    
    # Check if kubectl oidc-login plugin is installed
    if kubectl oidc-login --version &>/dev/null; then
        # Use default dev credentials
        KC_USERNAME="devuser@localhost.local"
        KC_PASSWORD="password"
        CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CURRENT_CONTEXT}')].context.cluster}")
        
        echo "   Creating OIDC kubectl configurations..."
        echo "   Using default dev credentials (devuser@localhost.local)"
        
        # Context 1: localhost (for local dev with port-forward)
        OIDC_USER_LOCAL="${CURRENT_USER}-oidc"
        OIDC_CONTEXT_LOCAL="${CURRENT_CONTEXT}-oidc"
        kubectl config set-credentials "${OIDC_USER_LOCAL}" \
            --exec-command=kubectl \
            --exec-api-version=client.authentication.k8s.io/v1beta1 \
            --exec-arg=oidc-login \
            --exec-arg=get-token \
            --exec-arg=--oidc-issuer-url="http://localhost:8080/realms/airm" \
            --exec-arg=--oidc-client-id="${ADMIN_CLIENT_ID}" \
            --exec-arg=--oidc-client-secret="${ADMIN_CLIENT_SECRET}" \
            --exec-arg=--username="${KC_USERNAME}" \
            --exec-arg=--password="${KC_PASSWORD}" \
            --exec-arg=--grant-type=password \
            --exec-arg=--insecure-skip-tls-verify >/dev/null 2>&1
        kubectl config set-context "${OIDC_CONTEXT_LOCAL}" \
            --cluster="${CLUSTER_NAME}" \
            --user="${OIDC_USER_LOCAL}" >/dev/null 2>&1
        echo "   ✓ Local OIDC context created: ${OIDC_CONTEXT_LOCAL} (requires port-forward)"
        
        # Context 2: cluster-internal (for e2e tests)
        OIDC_USER_CLUSTER="${CURRENT_USER}-oidc-cluster"
        OIDC_CONTEXT_CLUSTER="${CURRENT_CONTEXT}-oidc-cluster"
        kubectl config set-credentials "${OIDC_USER_CLUSTER}" \
            --exec-command=kubectl \
            --exec-api-version=client.authentication.k8s.io/v1beta1 \
            --exec-arg=oidc-login \
            --exec-arg=get-token \
            --exec-arg=--oidc-issuer-url="http://keycloak.keycloak.svc.cluster.local:8080/realms/airm" \
            --exec-arg=--oidc-client-id="${ADMIN_CLIENT_ID}" \
            --exec-arg=--oidc-client-secret="${ADMIN_CLIENT_SECRET}" \
            --exec-arg=--username="${KC_USERNAME}" \
            --exec-arg=--password="${KC_PASSWORD}" \
            --exec-arg=--grant-type=password \
            --exec-arg=--insecure-skip-tls-verify >/dev/null 2>&1
        kubectl config set-context "${OIDC_CONTEXT_CLUSTER}" \
            --cluster="${CLUSTER_NAME}" \
            --user="${OIDC_USER_CLUSTER}" >/dev/null 2>&1
        echo "   ✓ Cluster OIDC context created: ${OIDC_CONTEXT_CLUSTER} (for e2e tests)"
        
        echo "   ℹ️  Switch contexts with: kubectl config use-context <context-name>"
    else
        echo "   ⚠️  kubectl oidc-login plugin not found. Install with: kubectl krew install oidc-login"
    fi
else
    echo "   ⚠️  Could not retrieve Keycloak client credentials - skipping OIDC setup"
fi

# Generate .env files with credentials from cluster
echo ""
echo "📝 Generating .env files with cluster credentials..."

# Check if llm-studio-core path exists
if [ ! -d "$LLM_STUDIO_CORE_PATH" ]; then
    echo "⚠️  LLM Studio Core path not found: $LLM_STUDIO_CORE_PATH"
    echo "   Set LLM_STUDIO_CORE_PATH environment variable to the correct path"
    echo "   Skipping .env file generation"
else
    # Get credentials
    # Get credentials
    DB_USER=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 -d)
    DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 -d)
    KC_ADMIN_ID=$(kubectl get secret airm-keycloak-admin-client -n airm -o jsonpath='{.data.client-id}' | base64 -d)
    KC_ADMIN_SECRET=$(kubectl get secret airm-keycloak-admin-client -n airm -o jsonpath='{.data.client-secret}' | base64 -d)
    KC_UI_SECRET=$(kubectl get secret airm-keycloak-ui-creds -n airm -o jsonpath='{.data.KEYCLOAK_SECRET}' | base64 -d 2>/dev/null || echo "")
    RABBITMQ_USER=$(kubectl get secret airm-rabbitmq-admin -n airm -o jsonpath='{.data.username}' | base64 -d)
    RABBITMQ_PASS=$(kubectl get secret airm-rabbitmq-admin -n airm -o jsonpath='{.data.password}' | base64 -d)

    # Create API .env file
    API_ENV_FILE="${LLM_STUDIO_CORE_PATH}/services/airm/api/.env"
    mkdir -p "$(dirname "$API_ENV_FILE")"
    cat > "$API_ENV_FILE" <<EOF
# Database
DATABASE_HOST="localhost"
DATABASE_PORT=5432
DATABASE_USER="$DB_USER"
DATABASE_PASSWORD="$DB_PASSWORD"
DATABASE_NAME="airm"

# Keycloak
KEYCLOAK_ADMIN_SERVER_URL="http://localhost:8080"
KEYCLOAK_ADMIN_CLIENT_ID="$KC_ADMIN_ID"
KEYCLOAK_ADMIN_CLIENT_SECRET="$KC_ADMIN_SECRET"
KEYCLOAK_REALM="airm"

# RabbitMQ
RABBITMQ_HOST="localhost"
RABBITMQ_PORT=5672
RABBITMQ_MANAGEMENT_URL="http://localhost:15672/api"
RABBITMQ_ADMIN_USER="$RABBITMQ_USER"
RABBITMQ_ADMIN_PASSWORD="$RABBITMQ_PASS"
RABBITMQ_AIRM_COMMON_VHOST="vh_airm_common"
RABBITMQ_AIRM_COMMON_QUEUE="airm_common"

# MinIO
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_URL=http://localhost:9000

# Cluster Auth (optional - pod may not be running)
CLUSTER_AUTH_URL=http://localhost:48012
CLUSTER_AUTH_ADMIN_TOKEN=""

# Other
POST_REGISTRATION_REDIRECT_URL="http://localhost:8010"
EOF

    # Create UI .env.local file
    UI_ENV_FILE="${LLM_STUDIO_CORE_PATH}/services/airm/ui/.env.local"
    mkdir -p "$(dirname "$UI_ENV_FILE")"
    cat > "$UI_ENV_FILE" <<EOF
# Next.js
NEXTAUTH_URL=http://localhost:8010
NEXTAUTH_SECRET="local-dev-secret-change-in-production"

# Keycloak
KEYCLOAK_ID="354a0fa1-35ac-4a6d-9c4d-d661129c2cd0"
KEYCLOAK_SECRET="$KC_UI_SECRET"
KEYCLOAK_ISSUER=http://localhost:8080/realms/airm

# AIRM API - use 127.0.0.1 instead of localhost to avoid IPv6
AIRM_API_SERVICE_URL=http://127.0.0.1:8001
EOF

    echo "✅ Generated .env files:"
    echo "   - $API_ENV_FILE"
    echo "   - $UI_ENV_FILE"
fi
echo ""
echo "📝 Next steps:"
echo "   1. Run API: cd ${LLM_STUDIO_CORE_PATH}/services/airm/api && uv run fastapi dev"
echo "   2. Run UI: cd ${LLM_STUDIO_CORE_PATH}/services/airm/ui && pnpm dev"
echo "   3. Open UI: http://localhost:8010"
echo ""

# Wait for Ctrl+C
wait
