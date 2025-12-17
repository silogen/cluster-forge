#!/bin/bash
# Port-forward cluster services for local AIRM development
# This allows running AIRM UI and API locally while connected to the Kind cluster

# Get script directory and derive paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_FORGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Default to parent directory (silogen-core is parent of cluster-forge)
SILOGEN_CORE_PATH="${SILOGEN_CORE_PATH:-$(cd "$CLUSTER_FORGE_ROOT/.." && pwd)}"

echo "🔌 Setting up port-forwards for local AIRM development..."
echo ""
echo "This will port-forward the following services:"
echo "  - PostgreSQL (5432)"
echo "  - RabbitMQ (5672, 15672)"
echo "  - MinIO (9000)"
echo "  - Cluster Auth (48012)"
echo ""
echo "Note: Keycloak is accessible via NodePort at http://localhost:8080"
echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Initialize status tracking using files (bash 3.2 compatible)
STATUS_DIR="/tmp/airm-portforward-status"
mkdir -p "$STATUS_DIR"
rm -f "$STATUS_DIR"/*

# Function to run port-forward in background and track PID
start_forward() {
    local display_name=$1
    local namespace=$2
    local service=$3
    local ports=$4
    local safe_name=$(echo "$display_name" | tr ' ' '_')
    
    # Check if service exists
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        echo "⚠️  Not Found" > "$STATUS_DIR/${safe_name}_status"
        echo "Service $service not found in namespace $namespace" > "$STATUS_DIR/${safe_name}_error"
        return 1
    fi
    
    # Run port-forward in a loop to auto-restart on connection loss
    (
        while true; do
            kubectl port-forward -n "$namespace" "svc/$service" $ports 2>&1 | \
                grep -v "Handling connection" | \
                while IFS= read -r line; do
                    if [[ "$line" =~ "Forwarding from" ]]; then
                        echo "✓ Running" > "$STATUS_DIR/${safe_name}_status"
                        rm -f "$STATUS_DIR/${safe_name}_error"
                    elif [[ "$line" =~ "error" ]] || [[ "$line" =~ "unable" ]]; then
                        echo "❌ Error" > "$STATUS_DIR/${safe_name}_status"
                        echo "$line" > "$STATUS_DIR/${safe_name}_error"
                    fi
                done
            echo "🔄 Reconnecting" > "$STATUS_DIR/${safe_name}_status"
            sleep 2
        done
    ) &
    local pid=$!
    echo "$pid" > "$STATUS_DIR/${safe_name}_pid"
    echo "🔄 Starting" > "$STATUS_DIR/${safe_name}_status"
    echo "$pid" >> /tmp/airm-portforward-pids.txt
    sleep 1
    
    # Check if the process is still running
    if kill -0 $pid 2>/dev/null; then
        echo "✓ Running" > "$STATUS_DIR/${safe_name}_status"
        return 0
    else
        echo "❌ Failed" > "$STATUS_DIR/${safe_name}_status"
        echo "Failed to start" > "$STATUS_DIR/${safe_name}_error"
        return 1
    fi
}

# Cleanup function
cleanup() {
    # Clear the monitoring loop flag
    MONITORING=false
    
    # Kill the monitor background process
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null
    fi
    
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
    
    # Clean up status directory
    rm -rf "$STATUS_DIR"
    
    echo "✅ All port-forwards stopped"
    exit 0
}

# Helper function to get status for a service
get_status() {
    local service=$1
    local safe_name=$(echo "$service" | tr ' ' '_')
    if [ -f "$STATUS_DIR/${safe_name}_status" ]; then
        cat "$STATUS_DIR/${safe_name}_status"
    else
        echo "⚠️  Not Started"
    fi
}

# Helper function to get PID for a service
get_pid() {
    local service=$1
    local safe_name=$(echo "$service" | tr ' ' '_')
    if [ -f "$STATUS_DIR/${safe_name}_pid" ]; then
        cat "$STATUS_DIR/${safe_name}_pid"
    else
        echo "-"
    fi
}

# Helper function to get error for a service
get_error() {
    local service=$1
    local safe_name=$(echo "$service" | tr ' ' '_')
    if [ -f "$STATUS_DIR/${safe_name}_error" ]; then
        cat "$STATUS_DIR/${safe_name}_error"
    else
        echo ""
    fi
}

# Function to display resource monitoring
show_monitoring() {
    clear
    echo "╔════════════════════════════════════════════════════════════════════════════╗"
    echo "║               🔌 AIRM Local Development Port-Forward Monitor               ║"
    echo "╚════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Cluster Resources
    echo "┌─ 📊 Cluster Resources ─────────────────────────────────────────────────────┐"
    
    # Get node information
    local node_info=$(kubectl get nodes -o json 2>/dev/null)
    if [ $? -eq 0 ]; then
        local node_name=$(echo "$node_info" | jq -r '.items[0].metadata.name')
        local cpu_capacity=$(echo "$node_info" | jq -r '.items[0].status.capacity.cpu')
        local memory_capacity=$(echo "$node_info" | jq -r '.items[0].status.capacity.memory' | sed 's/Ki//')
        local storage_capacity=$(echo "$node_info" | jq -r '.items[0].status.capacity["ephemeral-storage"]' | sed 's/Ki//')
        
        # Convert to human-readable
        memory_capacity_gb=$(awk "BEGIN {printf \"%.1f\", $memory_capacity/1024/1024}")
        storage_capacity_gb=$(awk "BEGIN {printf \"%.1f\", $storage_capacity/1024/1024}")
        
        # Get resource allocation
        local node_desc=$(kubectl describe node "$node_name" 2>/dev/null)
        local cpu_requests=$(echo "$node_desc" | grep -A 10 "Allocated resources:" | grep "cpu" | awk '{print $3}' | tr -d '()%')
        local memory_requests=$(echo "$node_desc" | grep -A 10 "Allocated resources:" | grep "memory" | awk '{print $3}' | tr -d '()%')
        local storage_requests=$(echo "$node_desc" | grep -A 10 "Allocated resources:" | grep "ephemeral-storage" | awk '{print $3}' | tr -d '()%')
        
        # Get actual disk usage from the node
        local disk_usage=""
        local disk_usage_percent=0
        if command -v docker &> /dev/null && [[ "$node_name" == *"control-plane"* ]]; then
            # For kind clusters, check the docker container's disk usage
            local container_name=$(docker ps --filter "name=$node_name" --format "{{.Names}}" 2>/dev/null | head -1)
            if [ -n "$container_name" ]; then
                disk_usage=$(docker exec "$container_name" df -h / 2>/dev/null | tail -1 | awk '{print $5, "of", $2, "used"}')
                disk_usage_percent=$(docker exec "$container_name" df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
            fi
        fi
        
        # If we couldn't get docker info, try kubectl debug (works for any cluster)
        if [ -z "$disk_usage" ]; then
            local debug_output=$(kubectl debug node/"$node_name" -it --image=busybox -- df -h / 2>/dev/null | grep -v "Defaulting\|Removing\|pod/" | tail -1)
            if [ -n "$debug_output" ]; then
                disk_usage=$(echo "$debug_output" | awk '{print $5, "of", $2, "used"}')
                disk_usage_percent=$(echo "$debug_output" | awk '{print $5}' | tr -d '%')
            fi
        fi
        
        # Default to 0 if empty
        cpu_requests=${cpu_requests:-0}
        memory_requests=${memory_requests:-0}
        storage_requests=${storage_requests:-0}
        disk_usage_percent=${disk_usage_percent:-0}
        
        # Create visual bars
        local cpu_bar=$(create_bar $cpu_requests)
        local mem_bar=$(create_bar $memory_requests)
        local disk_bar=$(create_bar $disk_usage_percent)
        
        echo "│ Node: $node_name"
        echo "│"
        echo "│ CPU:     ${cpu_bar} ${cpu_requests}% (${cpu_capacity} cores)"
        echo "│ Memory:  ${mem_bar} ${memory_requests}% (${memory_capacity_gb}Gi)"
        if [ -n "$disk_usage" ]; then
            echo "│ Disk:    ${disk_bar} ${disk_usage}"
        else
            echo "│ Disk:    Unable to fetch disk usage"
        fi
    else
        echo "│ ❌ Unable to fetch cluster resource information"
    fi
    
    # Pod count
    local pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pod_running=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pod_pending=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pod_failed=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    echo "│"
    echo "│ Pods:    ${pod_running}/${pod_count} running"
    if [ "$pod_pending" -gt 0 ]; then
        echo "│          ⚠️  ${pod_pending} pending"
    fi
    if [ "$pod_failed" -gt 0 ]; then
        echo "│          ❌ ${pod_failed} failed"
    fi
    echo "└────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Port-forward status
    echo "┌─ 🔌 Port-Forward Status ───────────────────────────────────────────────────┐"
    printf "│ %-20s %-15s %s\n" "Service" "Status" "PID"
    echo "├────────────────────────────────────────────────────────────────────────────┤"
    
    for service in "PostgreSQL" "RabbitMQ" "MinIO" "Cluster Auth"; do
        local status=$(get_status "$service")
        local pid=$(get_pid "$service")
        printf "│ %-20s %-15s %s\n" "$service" "$status" "$pid"
        
        # Show error if exists
        local error=$(get_error "$service")
        if [ -n "$error" ]; then
            echo "│   └─ Error: $error"
        fi
    done
    echo "├────────────────────────────────────────────────────────────────────────────┤"
    echo "│ Keycloak             ✓ NodePort      (http://localhost:8080)              │"
    echo "└────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Press Ctrl+C to stop all port-forwards"
    echo "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
}

# Function to create a visual progress bar
create_bar() {
    local percentage=$1
    local bar_length=20
    local filled=$((percentage * bar_length / 100))
    local empty=$((bar_length - filled))
    
    # Color coding based on usage
    local color=""
    if [ "$percentage" -ge 90 ]; then
        color="🔴"  # Red for critical
    elif [ "$percentage" -ge 75 ]; then
        color="🟡"  # Yellow for warning
    else
        color="🟢"  # Green for OK
    fi
    
    printf "%s [" "$color"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "]"
}

trap cleanup SIGINT SIGTERM EXIT

# Clean up any previous PIDs file
rm -f /tmp/airm-portforward-pids.txt

# Wait for Keycloak to be ready
echo "⏳ Waiting for Keycloak to be ready..."
if ! kubectl wait --for=condition=available --timeout=60s deployment/keycloak -n keycloak > /dev/null 2>&1; then
    echo "❌ ERROR: Keycloak is not ready"
    echo "   Please ensure Keycloak deployment is running: kubectl get deployment -n keycloak keycloak"
    exit 1
fi

echo "✅ Keycloak is ready"

# Check if devuser needs password reset
echo "🔧 Configuring devuser account..."
KEYCLOAK_POD=$(kubectl get pod -n keycloak -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

# Get admin credentials
ADMIN_PASSWORD=$(kubectl get secret -n keycloak keycloak-credentials -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 -d)

# Use kcadm.sh to reset password (non-temporary)
if ! kubectl exec -n keycloak "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user silogen-admin \
    --password "$ADMIN_PASSWORD" > /dev/null 2>&1; then
    echo "❌ ERROR: Could not authenticate to Keycloak admin API"
    echo "   Please check Keycloak admin credentials"
    exit 1
fi

# Reset password to non-temporary
if ! kubectl exec -n keycloak "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh set-password \
    --server http://localhost:8080 \
    --target-realm airm \
    --username "devuser@localhost.local" \
    --new-password "password" > /dev/null 2>&1; then
    echo "❌ ERROR: Could not configure devuser password"
    echo "   OIDC authentication will not work without password reset"
    exit 1
fi

echo "   ✓ devuser password configured (non-temporary)"

echo ""
echo "🔐 Configuring kubectl OIDC authentication..."

# Get the current context and user
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_USER="${CURRENT_CONTEXT}"
echo "   Current context: ${CURRENT_CONTEXT}"

# Get Keycloak k8s client credentials (configured with groups scope)
K8S_CLIENT_ID="k8s"
K8S_CLIENT_SECRET=$(kubectl get secret -n keycloak airm-realm-credentials -o jsonpath='{.data.K8S_CLIENT_SECRET}' 2>/dev/null | base64 -d)

if [ -n "$K8S_CLIENT_SECRET" ]; then
    echo "   Found k8s client ID: ${K8S_CLIENT_ID}"
    
    # Check if kubectl oidc-login plugin is installed
    if kubectl oidc-login --version &>/dev/null; then
        # Use default dev credentials
        KC_USERNAME="devuser@localhost.local"
        KC_PASSWORD="password"
        CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CURRENT_CONTEXT}')].context.cluster}")
        
        echo "   Creating OIDC kubectl configurations..."
        echo "   Using default dev credentials (devuser@localhost.local)"
        
        # Context 1: localhost (for local dev - uses NodePort, no port-forward needed)
        OIDC_USER_LOCAL="${CURRENT_USER}-oidc"
        OIDC_CONTEXT_LOCAL="${CURRENT_CONTEXT}-oidc"
        kubectl config set-credentials "${OIDC_USER_LOCAL}" \
            --exec-command=kubectl \
            --exec-api-version=client.authentication.k8s.io/v1beta1 \
            --exec-arg=oidc-login \
            --exec-arg=get-token \
            --exec-arg=--oidc-issuer-url="http://localhost:8080/realms/airm" \
            --exec-arg=--oidc-client-id="${K8S_CLIENT_ID}" \
            --exec-arg=--oidc-client-secret="${K8S_CLIENT_SECRET}" \
            --exec-arg=--username="${KC_USERNAME}" \
            --exec-arg=--password="${KC_PASSWORD}" \
            --exec-arg=--grant-type=password \
            --exec-arg=--insecure-skip-tls-verify >/dev/null 2>&1
        kubectl config set-context "${OIDC_CONTEXT_LOCAL}" \
            --cluster="${CLUSTER_NAME}" \
            --user="${OIDC_USER_LOCAL}" >/dev/null 2>&1
        echo "   ✓ Local OIDC context created: ${OIDC_CONTEXT_LOCAL}"
        echo "   ℹ️  Switch contexts with: kubectl config use-context <context-name>"
    else
        echo "   ⚠️  kubectl oidc-login plugin not found. Install with: kubectl krew install oidc-login"
    fi
else
    echo "   ⚠️  Could not retrieve Keycloak client credentials - skipping OIDC setup"
fi

echo ""
echo "🔌 Starting port-forwards..."

# Start all port-forwards (silently in background)
start_forward "PostgreSQL" "airm" "airm-cnpg-rw" "5432:5432"
start_forward "RabbitMQ" "airm" "airm-rabbitmq" "5672:5672 15672:15672"
start_forward "MinIO" "minio-tenant-default" "minio" "9000:80"
start_forward "Cluster Auth" "cluster-auth" "cluster-auth" "48012:8081"
# Optional: Prometheus (uncomment if otel-lgtm-stack is deployed)
# start_forward "Prometheus" "otel-lgtm-stack" "lgtm-stack" "9090:3000"

# Wait a moment for port-forwards to initialize
sleep 2

# Generate .env files with credentials from cluster
echo ""
echo "📝 Generating .env files with cluster credentials..."

# Check if silogen-core path exists
if [ ! -d "$SILOGEN_CORE_PATH" ]; then
    echo "⚠️  Silogen Core path not found: $SILOGEN_CORE_PATH"
    echo "   Set SILOGEN_CORE_PATH environment variable to the correct path"
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
    API_ENV_FILE="${SILOGEN_CORE_PATH}/services/airm/api/.env"
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
    UI_ENV_FILE="${SILOGEN_CORE_PATH}/services/airm/ui/.env.local"
    mkdir -p "$(dirname "$UI_ENV_FILE")"
    cat > "$UI_ENV_FILE" <<EOF
# Next.js
NEXTAUTH_URL=http://localhost:8010
NEXTAUTH_SECRET="local-dev-secret-change-in-production"

# Keycloak
KEYCLOAK_ID="354a0fa1-35ac-4a6d-9c4d-d661129c2cd0"
KEYCLOAK_SECRET="$KC_UI_SECRET"
KEYCLOAK_ISSUER=http://localhost:8080/realms/airm

# AIRM API
AIRM_API_SERVICE_URL=http://localhost:8001

# Force Node.js to prefer IPv4 to avoid IPv6 connection issues
NODE_OPTIONS="--dns-result-order=ipv4first"
EOF

    echo "✅ Generated .env files:"
    echo "   - $API_ENV_FILE"
    echo "   - $UI_ENV_FILE"
fi

# Start monitoring loop
MONITORING=true

# Display initial screen
show_monitoring

# Background loop to refresh display
(
    while $MONITORING; do
        sleep 5
        if $MONITORING; then
            show_monitoring
        fi
    done
) &
MONITOR_PID=$!

# Wait for Ctrl+C
wait
