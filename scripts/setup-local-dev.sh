#!/bin/bash

# Local Kind Development Setup Script for Cluster-Forge
# This script sets up a minimal cluster-forge deployment for local Kind clusters.
# It is idempotent — safe to re-run without deleting the cluster. Components that
# are already deployed and healthy are skipped. AIRM and AIWB are always redeployed.
#
# Environment variables:
#   SKIP_IMAGE_PRELOAD=1     - Skip pre-loading container images
#   SKIP_LOCAL_BUILD=1       - Skip building local AIRM/AIWB images
#   LLM_STUDIO_CORE_PATH    - Path to llm-studio-core repo (default: ~/core)
#   GHCR_TOKEN               - GitHub token with read:packages scope (fallback for private GHCR images)
#   GHCR_USERNAME            - GitHub username (default: extracted from git config)
#   FORCE_REDEPLOY=1         - Force redeployment of all components (ignore readiness checks)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="${1:-localhost.local}"
LLM_STUDIO_CORE_PATH="${LLM_STUDIO_CORE_PATH:-${HOME}/core}"
KUBE_VERSION=1.33

echo "🔧 Setting up cluster-forge for local Kind development..."
echo "📋 Domain: ${DOMAIN}"
echo "📂 Core repo: ${LLM_STUDIO_CORE_PATH}"
echo ""

# ─── Readiness check helpers ─────────────────────────────────────────────────

deployment_ready() {
    local ns="$1" name="$2"
    kubectl get deploy "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'
}

statefulset_ready() {
    local ns="$1" name="$2"
    kubectl get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'
}

pod_running() {
    local ns="$1" name="$2"
    kubectl get pod "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
}

job_completed() {
    local ns="$1" name="$2"
    kubectl get job "${name}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q "True"
}

secret_exists() {
    local ns="$1" name="$2"
    kubectl get secret "${name}" -n "${ns}" &>/dev/null
}

should_skip() {
    [ "${FORCE_REDEPLOY}" != "1" ]
}

# ─── Cluster check ───────────────────────────────────────────────────────────

if ! kubectl cluster-info &> /dev/null; then
    echo "❌ ERROR: No Kubernetes cluster found. Please create a Kind cluster first:"
    echo "   kind create cluster --name cluster-forge-local --config kind-cluster-config.yaml"
    exit 1
fi

# Apply AMD certificates if fix_kind_certs.sh exists
if [ -f "${SCRIPT_DIR}/fix_kind_certs.sh" ]; then
    echo "🔐 Applying AMD certificates to Kind cluster..."
    bash "${SCRIPT_DIR}/fix_kind_certs.sh"
fi

# Check prerequisites
echo "🔍 Checking prerequisites..."
for cmd in kubectl helm yq openssl; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ ERROR: $cmd is not installed"
        exit 1
    fi
done

cd "${ROOT_DIR}"

# Update domain in values file
echo "📝 Updating domain to ${DOMAIN} in values_local_kind.yaml..."
yq eval '.global.domain = "'${DOMAIN}'"' -i root/values_local_kind.yaml

# ─── Namespaces (always idempotent) ──────────────────────────────────────────

echo "📦 Creating namespaces..."
for ns in argocd cf-gitea cf-openbao airm aim-system keycloak aiwb; do
    kubectl create ns "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# ─── GHCR pull secrets ───────────────────────────────────────────────────────

HAS_GHCR_CREDS=0

setup_ghcr_pull_secrets() {
    local NAMESPACES=("airm" "aim-system" "keycloak" "aiwb")
    local SECRET_NAME="ghcr-pull-secret"

    if [ -n "${GHCR_TOKEN:-}" ]; then
        local USERNAME="${GHCR_USERNAME:-$(git config user.name 2>/dev/null || echo "token")}"
        echo "🔑 Creating GHCR pull secrets using GHCR_TOKEN (user: ${USERNAME})..."
        for NS in "${NAMESPACES[@]}"; do
            kubectl create secret docker-registry "${SECRET_NAME}" \
                --namespace="${NS}" \
                --docker-server=ghcr.io \
                --docker-username="${USERNAME}" \
                --docker-password="${GHCR_TOKEN}" \
                --dry-run=client -o yaml | kubectl apply -f -
            # Ensure SA has the pull secret (wait briefly for SA to exist in new namespaces)
            kubectl get sa default -n "${NS}" >/dev/null 2>&1 || sleep 2
            kubectl patch serviceaccount default -n "${NS}" \
                -p "{\"imagePullSecrets\": [{\"name\": \"${SECRET_NAME}\"}]}" || true
        done
        echo "   ✅ GHCR pull secrets created"
        HAS_GHCR_CREDS=1
        return 0
    fi

    local DOCKER_CONFIG="${HOME}/.docker/config.json"
    if [ -f "${DOCKER_CONFIG}" ] && grep -q "ghcr.io" "${DOCKER_CONFIG}" 2>/dev/null; then
        echo "🔑 Creating GHCR pull secrets from Docker credentials..."
        for NS in "${NAMESPACES[@]}"; do
            kubectl create secret generic "${SECRET_NAME}" \
                --namespace="${NS}" \
                --from-file=.dockerconfigjson="${DOCKER_CONFIG}" \
                --type=kubernetes.io/dockerconfigjson \
                --dry-run=client -o yaml | kubectl apply -f -
            kubectl get sa default -n "${NS}" >/dev/null 2>&1 || sleep 2
            kubectl patch serviceaccount default -n "${NS}" \
                -p "{\"imagePullSecrets\": [{\"name\": \"${SECRET_NAME}\"}]}" || true
        done
        echo "   ✅ GHCR pull secrets created from Docker config"
        HAS_GHCR_CREDS=1
        return 0
    fi

    echo "⚠️  No GHCR credentials found. Will build images from local source instead."
    HAS_GHCR_CREDS=0
}

setup_ghcr_pull_secrets

# ─── Storage class (idempotent) ──────────────────────────────────────────────

echo "💾 Creating default StorageClass..."
kubectl create -f - <<EOF || true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
EOF

# ─── Extract component values ────────────────────────────────────────────────

echo "📋 Extracting component values from root/values.yaml..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

yq eval '.apps.argocd.valuesObject' root/values.yaml > "$TEMP_DIR/argocd_values.yaml"
yq eval '.apps.openbao.valuesObject' root/values.yaml > "$TEMP_DIR/openbao_values.yaml"
yq eval '.apps.gitea.valuesObject' root/values.yaml > "$TEMP_DIR/gitea_values.yaml"

# ─── ArgoCD ──────────────────────────────────────────────────────────────────

if should_skip && statefulset_ready argocd argocd-application-controller \
   && deployment_ready argocd argocd-repo-server; then
    echo "✅ ArgoCD already running, skipping"
else
    echo "🚀 Deploying ArgoCD..."
    helm template --release-name argocd sources/argocd/8.3.5 \
      --namespace argocd \
      -f "$TEMP_DIR/argocd_values.yaml" \
      --set global.domain="argocd.${DOMAIN}" \
      --kube-version=${KUBE_VERSION} | kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -

    echo "⏳ Waiting for ArgoCD to be ready..."
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
fi

# ─── OpenBao ─────────────────────────────────────────────────────────────────

if should_skip && pod_running cf-openbao openbao-0 && secret_exists cf-openbao openbao-keys; then
    echo "✅ OpenBao already running and initialized, skipping deploy"
    # Ensure OpenBao is unsealed (it re-seals after cluster restart)
    SEALED=$(kubectl exec openbao-0 -n cf-openbao -- bao status -format=json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',''))" 2>/dev/null)
    if [ "${SEALED}" = "True" ]; then
        echo "🔓 OpenBao is sealed — unsealing..."
        UNSEAL_KEY=$(kubectl get secret openbao-keys -n cf-openbao \
            -o jsonpath='{.data.unseal_key}' | base64 -d)
        kubectl exec openbao-0 -n cf-openbao -- bao operator unseal "${UNSEAL_KEY}" >/dev/null
        echo "   ✅ OpenBao unsealed"
        # Trigger ExternalSecrets refresh so secrets sync immediately
        echo "   🔄 Triggering ExternalSecrets refresh..."
        for ns in $(kubectl get externalsecrets -A --no-headers -o custom-columns="NS:.metadata.namespace" 2>/dev/null | sort -u); do
            for es in $(kubectl get externalsecrets -n "${ns}" --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null); do
                kubectl annotate externalsecret "${es}" -n "${ns}" \
                    force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
            done
        done
        echo "   ✅ ExternalSecrets refresh triggered"
    fi
else
    echo "🔐 Deploying OpenBao..."
    helm template --release-name openbao sources/openbao/0.18.2 \
      -f "$TEMP_DIR/openbao_values.yaml" \
      --set ui.enabled=true \
      --namespace cf-openbao \
      --kube-version=${KUBE_VERSION} | kubectl apply -f -

    echo "⏳ Waiting for OpenBao to be ready..."
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

    if secret_exists cf-openbao openbao-keys; then
        echo "✅ OpenBao already initialized, skipping init"
    else
        echo "🔧 Initializing OpenBao..."
        sed -e "s|{{ .Values.domain }}|${DOMAIN}|g" \
            -e "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" \
            sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | kubectl apply -f -

        helm template --release-name openbao-init scripts/init-openbao-job \
          --set domain="${DOMAIN}" \
          --kube-version=${KUBE_VERSION} | kubectl apply -f -

        if ! kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao; then
            echo "⚠️  WARNING: OpenBao initialization job did not complete. Check logs:"
            echo "   kubectl logs -n cf-openbao job/openbao-init-job"
        fi
    fi
fi

# ─── Pre-load container images ────────────────────────────────────────────
# Pull images on the host (where Docker has registry creds / cache) and load
# into Kind. This avoids Docker Hub rate limits and GHCR auth issues inside
# the cluster.

if [ "${SKIP_IMAGE_PRELOAD}" = "1" ]; then
    echo "⏭️  Skipping image pre-load (SKIP_IMAGE_PRELOAD=1)"
else
    PRELOAD_IMAGES=(
        # Keycloak (private GHCR + Quay)
        "ghcr.io/silogen/keycloak-init:0.1"
        "quay.io/keycloak/keycloak:26.0.0"
        # Docker Hub images used by AIRM init containers / dependencies
        "busybox:1.37.0"
        "postgres:17-alpine"
        "docker.io/liquibase/liquibase:4.31"
        "rabbitmq:4.1.1-management"
    )

    for img in "${PRELOAD_IMAGES[@]}"; do
        if docker exec cluster-forge-local-control-plane crictl inspecti "${img}" >/dev/null 2>&1; then
            echo "✅ ${img} already in Kind, skipping"
            continue
        fi
        if docker image inspect "${img}" >/dev/null 2>&1 || docker pull "${img}" 2>/dev/null; then
            echo "📦 Loading ${img} into Kind..."
            kind load docker-image "${img}" --name cluster-forge-local 2>/dev/null || true
        else
            echo "⚠️  Could not pull ${img} — pods needing it may fail"
        fi
    done
fi

# ─── Build local images ─────────────────────────────────────────────────────
# Build from local source when: explicitly requested, OR no GHCR creds available.
# Without GHCR creds, private images can't be pulled — local build is the only path.

NEED_LOCAL_BUILD=0
if [ "${SKIP_LOCAL_BUILD}" = "1" ]; then
    echo "⏭️  Skipping local image build (SKIP_LOCAL_BUILD=1)"
elif [ "${HAS_GHCR_CREDS}" = "0" ]; then
    echo "🔨 No GHCR credentials — building images from local source is required"
    NEED_LOCAL_BUILD=1
elif [ -d "${LLM_STUDIO_CORE_PATH}" ]; then
    echo "🔨 Core repo found — building local images"
    NEED_LOCAL_BUILD=1
fi

if [ "${NEED_LOCAL_BUILD}" = "1" ]; then
    if [ -d "${LLM_STUDIO_CORE_PATH}" ]; then
        "${SCRIPT_DIR}/build-local-images.sh" --source-repo "${LLM_STUDIO_CORE_PATH}" || \
            echo "⚠️  Local image build had failures (some images may still work)"
    else
        echo "❌ ERROR: No GHCR credentials and core repo not found at: ${LLM_STUDIO_CORE_PATH}"
        echo "   Either:"
        echo "     - Set GHCR_TOKEN env var or run: docker login ghcr.io"
        echo "     - Set LLM_STUDIO_CORE_PATH to your local core repo (e.g. ~/core)"
        exit 1
    fi
fi

# ─── Gitea ───────────────────────────────────────────────────────────────────

if should_skip && deployment_ready cf-gitea gitea \
   && job_completed cf-gitea gitea-init-local-job; then
    echo "✅ Gitea already running and initialized, skipping deploy"
else
    echo "🚀 Deploying Gitea..."

    generate_password() {
        openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
    }

    # Only generate new password if secret doesn't exist
    if ! secret_exists cf-gitea gitea-admin-credentials; then
        kubectl create secret generic gitea-admin-credentials \
          --namespace=cf-gitea \
          --from-literal=username=silogen-admin \
          --from-literal=password=$(generate_password) \
          --dry-run=client -o yaml | kubectl apply -f -
    fi

    kubectl create configmap initial-cf-values \
      --from-file=initial-cf-values=root/values_local_kind.yaml \
      -n cf-gitea \
      --dry-run=client -o yaml | kubectl apply -f -

    helm template --release-name gitea sources/gitea/12.3.0 \
      -f "$TEMP_DIR/gitea_values.yaml" \
      --namespace cf-gitea \
      --set clusterDomain="${DOMAIN}" \
      --set gitea.config.server.ROOT_URL="http://gitea.${DOMAIN}" \
      --kube-version=${KUBE_VERSION} | kubectl apply -f -

    echo "⏳ Waiting for Gitea to be ready..."
    kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s

    if ! job_completed cf-gitea gitea-init-job; then
        echo "🔧 Initializing Gitea repositories..."
        # Delete previous job runs so they can be re-created
        kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found
        helm template --release-name gitea-init scripts/init-gitea-job \
          --set domain="${DOMAIN}" \
          --kube-version=${KUBE_VERSION} | kubectl apply -f -

        if ! kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea; then
            echo "⚠️  WARNING: Gitea initialization job did not complete. Check logs:"
            echo "   kubectl logs -n cf-gitea job/gitea-init-job"
        fi
    fi

    if ! job_completed cf-gitea gitea-init-local-job; then
        echo "🔧 Initializing Gitea (local)..."
        kubectl delete job gitea-init-local-job -n cf-gitea --ignore-not-found
        helm template --release-name gitea-init scripts/init-gitea-local-job \
          --set domain="${DOMAIN}" \
          --kube-version=${KUBE_VERSION} | kubectl apply -f - > /dev/null

        kubectl wait --for=condition=complete --timeout=600s job/gitea-init-local-job -n cf-gitea > /dev/null 2>&1
    fi
    echo "✅ Gitea initialized"
fi

# ─── Push repos to Gitea (always, fast if up-to-date) ────────────────────────

echo "📤 Pushing repositories to Gitea..."

"${ROOT_DIR}/scripts/push-repo-to-gitea.sh" "${ROOT_DIR}" "cluster-org" "cluster-forge"

if [ -d "${LLM_STUDIO_CORE_PATH}" ]; then
    "${ROOT_DIR}/scripts/push-repo-to-gitea.sh" "${LLM_STUDIO_CORE_PATH}" "cluster-org" "core"
else
    echo "⚠️  llm-studio-core not found at ${LLM_STUDIO_CORE_PATH}"
    echo "   AIRM will use charts from cluster-forge/sources/airm"
fi

echo "✅ Repositories pushed to Gitea"

# ─── Deploy ArgoCD applications ──────────────────────────────────────────────

echo "🎯 Deploying cluster-forge ArgoCD applications..."
helm template root -f root/values_local_kind.yaml \
  --set global.domain="${DOMAIN}" \
  --kube-version=${KUBE_VERSION} | kubectl apply -f -

# ─── NodePort services for local access ─────────────────────────────────────
# Kind maps NodePorts to host ports (see kind-cluster-config.yaml).
# The app charts only create ClusterIP services, so we add NodePort wrappers.
#   30080→8000  AIRM UI        30083→8083  AIRM API
#   30081→8001  AIWB UI        30084→8084  AIWB API
#   30082→8080  Keycloak

echo "🌐 Creating NodePort services for local access..."
kubectl apply -f - <<'NODEPORT_EOF'
apiVersion: v1
kind: Service
metadata:
  name: airm-ui-nodeport
  namespace: airm
spec:
  type: NodePort
  selector:
    app: airm-ui
  ports:
    - port: 8000
      targetPort: 8000
      nodePort: 30080
---
apiVersion: v1
kind: Service
metadata:
  name: airm-api-nodeport
  namespace: airm
spec:
  type: NodePort
  selector:
    app: airm-api
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30083
---
apiVersion: v1
kind: Service
metadata:
  name: aiwb-ui-nodeport
  namespace: aiwb
spec:
  type: NodePort
  selector:
    app: aiwb-ui
  ports:
    - port: 8000
      targetPort: 8000
      nodePort: 30081
---
apiVersion: v1
kind: Service
metadata:
  name: aiwb-api-nodeport
  namespace: aiwb
spec:
  type: NodePort
  selector:
    app: aiwb-api
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30084
NODEPORT_EOF

# ─── Bootstrap AIRM agent RabbitMQ credentials ──────────────────────────────
# The agent needs a RabbitMQ user/vhost and a Kubernetes secret to start.
# Normally the configure job creates these after a full Keycloak+API+RabbitMQ
# chain is ready. For local dev we short-circuit this by creating the RabbitMQ
# resources directly via rabbitmqctl and seeding the secret ourselves.

bootstrap_airm_agent() {
    local LOCAL_CLUSTER_ID="00000000-0000-0000-0000-000000000001"
    local RMQ_POD="airm-rabbitmq-server-0"
    local NS="airm"
    local SECRET_NAME="airm-rabbitmq-common-vhost-user"
    local CLUSTER_VHOST="vh_${LOCAL_CLUSTER_ID}"
    local COMMON_VHOST="vh_airm_common"

    if should_skip && secret_exists "${NS}" "${SECRET_NAME}"; then
        echo "✅ AIRM agent secret already exists, skipping bootstrap"
        return
    fi

    echo "🐇 Bootstrapping AIRM agent RabbitMQ credentials..."

    echo "   Waiting for RabbitMQ pod to be ready..."
    if ! kubectl wait --for=condition=ready "pod/${RMQ_POD}" -n "${NS}" --timeout=300s 2>/dev/null; then
        echo "⚠️  RabbitMQ pod not ready after 5 minutes — skipping AIRM agent bootstrap"
        return
    fi

    local LOCAL_CLUSTER_SECRET
    LOCAL_CLUSTER_SECRET=$(openssl rand -hex 32)

    echo "   Creating RabbitMQ vhosts and user..."
    kubectl exec "${RMQ_POD}" -n "${NS}" -- rabbitmqctl add_vhost "${CLUSTER_VHOST}" 2>/dev/null || true
    kubectl exec "${RMQ_POD}" -n "${NS}" -- rabbitmqctl add_vhost "${COMMON_VHOST}" 2>/dev/null || true

    if kubectl exec "${RMQ_POD}" -n "${NS}" -- rabbitmqctl add_user "${LOCAL_CLUSTER_ID}" "${LOCAL_CLUSTER_SECRET}" 2>/dev/null; then
        kubectl exec "${RMQ_POD}" -n "${NS}" -- rabbitmqctl set_user_tags "${LOCAL_CLUSTER_ID}" management
    else
        kubectl exec "${RMQ_POD}" -n "${NS}" -- \
            rabbitmqctl change_password "${LOCAL_CLUSTER_ID}" "${LOCAL_CLUSTER_SECRET}"
    fi

    # In production, admin.py uses restricted permissions and pre-creates queues
    # with admin credentials. For local dev we grant full access so the agent
    # can self-provision queues (including dead-letter exchanges that need read).
    kubectl exec "${RMQ_POD}" -n "${NS}" -- \
        rabbitmqctl set_permissions -p "${CLUSTER_VHOST}" "${LOCAL_CLUSTER_ID}" ".*" ".*" ".*"
    kubectl exec "${RMQ_POD}" -n "${NS}" -- \
        rabbitmqctl set_permissions -p "${COMMON_VHOST}" "${LOCAL_CLUSTER_ID}" ".*" ".*" ".*"

    # rabbitmqctl add_vhost doesn't auto-grant permissions (unlike the management
    # HTTP API), so the admin user also needs explicit access to the new vhosts.
    local ADMIN_USER
    ADMIN_USER=$(kubectl get secret airm-rabbitmq-admin -n "${NS}" \
        -o jsonpath='{.data.username}' | base64 -d 2>/dev/null)
    if [ -n "${ADMIN_USER}" ]; then
        kubectl exec "${RMQ_POD}" -n "${NS}" -- \
            rabbitmqctl set_permissions -p "${CLUSTER_VHOST}" "${ADMIN_USER}" ".*" ".*" ".*"
        kubectl exec "${RMQ_POD}" -n "${NS}" -- \
            rabbitmqctl set_permissions -p "${COMMON_VHOST}" "${ADMIN_USER}" ".*" ".*" ".*"
    fi

    kubectl create secret generic "${SECRET_NAME}" \
        --namespace="${NS}" \
        --from-literal=username="${LOCAL_CLUSTER_ID}" \
        --from-literal=password="${LOCAL_CLUSTER_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo "   ✅ AIRM agent RabbitMQ credentials ready (cluster ID: ${LOCAL_CLUSTER_ID})"
}

bootstrap_airm_agent

# ─── Configure Keycloak for local dev ──────────────────────────────────────

configure_keycloak_local_dev() {
    echo "🔑 Configuring Keycloak for local development..."

    local KC_URL="http://localhost:8080"
    local KC_ADMIN_USER="silogen-admin"
    local KC_ADMIN_PASS
    KC_ADMIN_PASS=$(kubectl get secret keycloak-credentials -n keycloak \
        -o jsonpath='{.data.KEYCLOAK_INITIAL_ADMIN_PASSWORD}' | base64 -d 2>/dev/null)

    if [ -z "${KC_ADMIN_PASS}" ]; then
        echo "⚠️  Could not read keycloak-credentials secret — skipping Keycloak config"
        return
    fi

    echo "   Waiting for Keycloak to be reachable..."
    local retries=0
    while ! curl -sf "${KC_URL}/realms/master" >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [ $retries -gt 60 ]; then
            echo "⚠️  Keycloak not reachable after 5 minutes — skipping config"
            return
        fi
        sleep 5
    done

    local TOKEN
    TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
        -d "client_id=admin-cli" \
        -d "username=${KC_ADMIN_USER}" \
        -d "password=${KC_ADMIN_PASS}" \
        -d "grant_type=password" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

    if [ -z "${TOKEN}" ]; then
        echo "⚠️  Could not get Keycloak admin token — skipping config"
        return
    fi

    # --- Admin user (admin/admin in master realm) ---
    local EXISTING_ADMIN
    EXISTING_ADMIN=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
        "${KC_URL}/admin/realms/master/users?username=admin&exact=true" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)

    if [ "${EXISTING_ADMIN}" = "0" ]; then
        echo "   Creating admin/admin user in master realm..."
        curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/master/users" \
            -d '{"username":"admin","enabled":true,"credentials":[{"type":"password","value":"admin","temporary":false}]}'

        local ADMIN_ID
        ADMIN_ID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
            "${KC_URL}/admin/realms/master/users?username=admin&exact=true" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
        if [ -n "${ADMIN_ID}" ]; then
            local ADMIN_ROLE
            ADMIN_ROLE=$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${KC_URL}/admin/realms/master/roles/admin")
            curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/master/users/${ADMIN_ID}/role-mappings/realm" \
                -d "[${ADMIN_ROLE}]"
        fi
        echo "   ✅ Admin user created (admin/admin)"
    else
        echo "   ✅ Admin user already exists"
    fi

    # --- Dev user (devuser@amd.com / password in airm realm) ---
    local DEVUSER_ID
    DEVUSER_ID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
        "${KC_URL}/admin/realms/airm/users?max=100" | python3 -c "
import json,sys
users=json.load(sys.stdin)
for u in users:
    if u['username'].startswith('devuser@'):
        print(u['id'])
        break
" 2>/dev/null)

    if [ -n "${DEVUSER_ID}" ]; then
        echo "   Updating devuser to devuser@amd.com..."
        curl -sf -o /dev/null -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/airm/users/${DEVUSER_ID}" \
            -d '{"username":"devuser@amd.com","email":"devuser@amd.com","emailVerified":true,"enabled":true,"firstName":"Dev","lastName":"User"}'
        curl -sf -o /dev/null -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/airm/users/${DEVUSER_ID}/reset-password" \
            -d '{"type":"password","value":"password","temporary":false}'
        echo "   ✅ Dev user configured (devuser@amd.com / password)"
    else
        echo "   Creating devuser@amd.com in airm realm..."
        curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/airm/users" \
            -d '{"username":"devuser@amd.com","email":"devuser@amd.com","emailVerified":true,"enabled":true,"firstName":"Dev","lastName":"User","credentials":[{"type":"password","value":"password","temporary":false}]}'
        echo "   ✅ Dev user created (devuser@amd.com / password)"
    fi

    # --- Assign Platform Administrator role to devuser ---
    local DEV_USER_ID
    DEV_USER_ID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
        "${KC_URL}/admin/realms/airm/users?username=devuser@amd.com&exact=true" | \
        python3 -c "import json,sys; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null)

    if [ -n "${DEV_USER_ID}" ]; then
        local PA_ROLE
        PA_ROLE=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
            "${KC_URL}/admin/realms/airm/roles/Platform Administrator" 2>/dev/null)

        if [ -z "${PA_ROLE}" ] || [ "${PA_ROLE}" = "" ]; then
            echo "   Creating 'Platform Administrator' realm role..."
            curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/airm/roles" \
                -d '{"name":"Platform Administrator"}'
            PA_ROLE=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
                "${KC_URL}/admin/realms/airm/roles/Platform Administrator")
        fi

        if [ -n "${PA_ROLE}" ]; then
            curl -sf -o /dev/null -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
                "${KC_URL}/admin/realms/airm/users/${DEV_USER_ID}/role-mappings/realm" \
                -d "[${PA_ROLE}]" 2>/dev/null
            echo "   ✅ Platform Administrator role assigned to devuser@amd.com"
        fi
    fi

    # --- Add localhost redirect URIs to OIDC clients ---
    local LOCAL_REDIRECT_URIS='[
        "http://localhost:8000/*", "http://localhost:8001/*",
        "http://localhost:8002/*", "http://localhost:8083/*",
        "http://localhost:8084/*", "http://localhost:3000/*",
        "http://localhost:3001/*",
        "http://127.0.0.1:8000/*", "http://127.0.0.1:8001/*",
        "http://127.0.0.1:8002/*", "http://127.0.0.1:8083/*",
        "http://127.0.0.1:8084/*"
    ]'

    echo "   Configuring localhost redirect URIs for OIDC clients..."
    curl -sf -H "Authorization: Bearer ${TOKEN}" \
        "${KC_URL}/admin/realms/airm/clients?max=100" | python3 -c "
import json, sys

local_uris = json.loads('${LOCAL_REDIRECT_URIS}')
clients = json.load(sys.stdin)
target_names = ['AIRM UI Client', 'AIRM Admin API Client']

for c in clients:
    if c.get('name') in target_names or c.get('clientId') == '354a0fa1-35ac-4a6d-9c4d-d661129c2cd0':
        current = set(c.get('redirectUris', []))
        needed = set(local_uris)
        if not needed.issubset(current):
            c['redirectUris'] = list(current | needed)
            print(json.dumps({'id': c['id'], 'payload': c}))
" 2>/dev/null | while IFS= read -r line; do
        local CLIENT_ID
        CLIENT_ID=$(echo "${line}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local PAYLOAD
        PAYLOAD=$(echo "${line}" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['payload']))")
        curl -sf -o /dev/null -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/airm/clients/${CLIENT_ID}" \
            -d "${PAYLOAD}"
    done
    echo "   ✅ Redirect URIs configured for local dev ports"

    # --- Sync Keycloak client secrets to app namespaces ---
    # OpenBao and Keycloak realm import generate different random secrets.
    # We need the app-side secrets to match what Keycloak actually uses.
    local KC_FRONTEND_SECRET
    KC_FRONTEND_SECRET=$(kubectl get secret airm-realm-credentials -n keycloak \
        -o jsonpath='{.data.FRONTEND_CLIENT_SECRET}' 2>/dev/null | base64 -d)

    if [ -n "${KC_FRONTEND_SECRET}" ]; then
        echo "   Syncing Keycloak client secrets to app namespaces..."
        local ENCODED_SECRET
        ENCODED_SECRET=$(echo -n "${KC_FRONTEND_SECRET}" | base64)

        # AIWB namespace
        if kubectl get secret airm-ui-keycloak-secret -n aiwb >/dev/null 2>&1; then
            kubectl patch secret airm-ui-keycloak-secret -n aiwb --type merge \
                -p "{\"data\":{\"value\":\"${ENCODED_SECRET}\"}}" 2>/dev/null
        fi

        # AIRM namespace
        if kubectl get secret airm-keycloak-ui-creds -n airm >/dev/null 2>&1; then
            kubectl patch secret airm-keycloak-ui-creds -n airm --type merge \
                -p "{\"data\":{\"KEYCLOAK_SECRET\":\"${ENCODED_SECRET}\"}}" 2>/dev/null
        fi
        echo "   ✅ Client secrets synced"
    fi
}

# --- Patch deployment env vars for local dev ---
# Disables ArgoCD selfHeal for the app, then patches the deployment directly.
# selfHeal is unnecessary for local dev and would revert our env overrides.
patch_local_dev_env() {
    local app="$1" ns="$2" deploy="$3" env_name="$4" env_value="$5"

    if ! kubectl get deploy "${deploy}" -n "${ns}" >/dev/null 2>&1; then
        return
    fi

    local current
    current=$(kubectl get deploy "${deploy}" -n "${ns}" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"${env_name}\")].value}" 2>/dev/null)

    if [ "${current}" != "${env_value}" ]; then
        echo "🔧 Patching ${ns}/${deploy}: ${env_name}=${env_value}"
        kubectl patch application "${app}" -n argocd --type json \
            -p '[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":false}]' 2>/dev/null || true
        kubectl set env "deploy/${deploy}" -n "${ns}" "${env_name}=${env_value}"
        echo "   ✅ Patched"
    fi
}

# Only configure Keycloak if it's deployed (pod running)
if kubectl get deploy keycloak -n keycloak >/dev/null 2>&1; then
    configure_keycloak_local_dev
fi

patch_local_dev_env airm airm airm-ui NEXTAUTH_URL "http://localhost:8000"
patch_local_dev_env aiwb aiwb aiwb-ui NEXTAUTH_URL "http://localhost:8001"

# ─── AIRM demo onboarding ────────────────────────────────────────────────────
# The helm configure job constructs the user email from the app domain, which
# doesn't match our canonical devuser@amd.com. We disable the job and perform
# the onboarding directly so we can use the correct user.

configure_airm_demo() {
    local NS="airm"
    local AIRM_API="http://airm-api.airm.svc.cluster.local"
    local KC_URL="http://keycloak.keycloak.svc.cluster.local:8080"

    # Disable the helm configure job (it uses a domain-derived email that
    # doesn't match our devuser@amd.com) and handle onboarding ourselves.
    kubectl patch application airm -n argocd --type json \
        -p '[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":false}]' 2>/dev/null || true
    kubectl delete job airm-configure -n "${NS}" --ignore-not-found >/dev/null 2>&1

    # Wait for AIRM API to be healthy (check from inside the cluster)
    echo "   Waiting for AIRM API..."
    local retries=0
    while ! kubectl exec deploy/airm-api -n "${NS}" -c airm -- \
            curl -sf "${AIRM_API}/v1/health" >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [ $retries -gt 60 ]; then
            echo "⚠️  AIRM API not reachable after 5 minutes — skipping demo onboarding"
            return
        fi
        sleep 5
    done

    # All API calls go through the airm-api pod to reach cluster-internal services
    local KC_CLIENT_SECRET
    KC_CLIENT_SECRET=$(kubectl get secret airm-keycloak-ui-creds -n "${NS}" \
        -o jsonpath='{.data.KEYCLOAK_SECRET}' 2>/dev/null | base64 -d)

    if [ -z "${KC_CLIENT_SECRET}" ]; then
        echo "⚠️  Could not read Keycloak client secret — skipping demo onboarding"
        return
    fi

    local TOKEN
    TOKEN=$(kubectl exec deploy/airm-api -n "${NS}" -c airm -- \
        curl -sf -d "client_id=354a0fa1-35ac-4a6d-9c4d-d661129c2cd0" \
        -d "username=devuser@amd.com" -d "password=password" \
        -d "grant_type=password" -d "client_secret=${KC_CLIENT_SECRET}" \
        "${KC_URL}/realms/airm/protocol/openid-connect/token" 2>/dev/null | \
        grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "${TOKEN}" ]; then
        echo "⚠️  Could not get Keycloak token for devuser@amd.com — skipping demo onboarding"
        return
    fi

    # Check if cluster already registered
    local EXISTING_CLUSTER
    EXISTING_CLUSTER=$(kubectl exec deploy/airm-api -n "${NS}" -c airm -- \
        curl -sf -H "Authorization: Bearer ${TOKEN}" "${AIRM_API}/v1/clusters" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)

    if [ -n "${EXISTING_CLUSTER}" ]; then
        echo "   ✅ AIRM cluster already registered (${EXISTING_CLUSTER})"
        return
    fi

    echo "   Registering cluster with AIRM API..."
    local CLUSTER_RESP
    CLUSTER_RESP=$(kubectl exec deploy/airm-api -n "${NS}" -c airm -- \
        curl -sf -X POST "${AIRM_API}/v1/clusters" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"workloads_base_url":"https://workspaces.localhost.local/","kube_api_url":"https://kubernetes.default.svc"}' 2>/dev/null)

    local NEW_CLUSTER_ID NEW_SECRET
    NEW_CLUSTER_ID=$(echo "${CLUSTER_RESP}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    NEW_SECRET=$(echo "${CLUSTER_RESP}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('user_secret',''))" 2>/dev/null)

    if [ -z "${NEW_CLUSTER_ID}" ] || [ "${NEW_CLUSTER_ID}" = "" ]; then
        echo "⚠️  Cluster registration failed — agent will run but heartbeats won't be tracked"
        return
    fi

    echo "   ✅ Cluster registered (${NEW_CLUSTER_ID})"

    # Update agent secret with API-issued credentials so heartbeats are recognised
    if [ -n "${NEW_SECRET}" ]; then
        kubectl create secret generic airm-rabbitmq-common-vhost-user \
            --namespace="${NS}" \
            --from-literal=username="${NEW_CLUSTER_ID}" \
            --from-literal=password="${NEW_SECRET}" \
            --dry-run=client -o yaml | kubectl apply -f -
        kubectl rollout restart deploy/airm-agent -n "${NS}" 2>/dev/null || true
        echo "   ✅ Agent secret updated with API-issued credentials"
    fi
}

echo "🎯 Configuring AIRM demo environment..."
if kubectl get deploy airm-api -n airm >/dev/null 2>&1; then
    configure_airm_demo
fi

echo ""
echo "✅ Local Kind cluster-forge setup complete!"
echo ""
echo "📋 Access Information:"
echo ""
echo "1. ArgoCD UI:"
echo "   kubectl port-forward svc/argocd-server -n argocd 9090:443"
echo "   Open: https://localhost:9090 (accept self-signed cert)"
echo "   Username: admin"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo "2. Gitea UI:"
echo "   kubectl port-forward svc/gitea-http -n cf-gitea 3000:3000"
echo "   Open: http://localhost:3000"
echo "   Username: kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath=\"{.data.username}\" | base64 -d"
echo "   Password: kubectl -n cf-gitea get secret gitea-admin-credentials -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
echo "3. Keycloak Admin Console:"
echo "   http://localhost:8080/admin"
echo "   Username: admin"
echo "   Password: admin"
echo ""
echo "4. Keycloak Dev User (airm realm):"
echo "   Username: devuser@amd.com"
echo "   Password: password"
echo ""
echo "5. AIRM:  UI → http://localhost:8000   API → http://localhost:8083   Swagger → http://localhost:8083/docs"
echo "6. AIWB:  UI → http://localhost:8001   API → http://localhost:8084   Swagger → http://localhost:8084/docs"
echo ""
echo "7. OpenBao UI:"
echo "   kubectl port-forward svc/openbao-active -n cf-openbao 8200:8200"
echo "   Open: http://localhost:8200"
echo "   Token: kubectl -n cf-openbao get secret openbao-keys -o jsonpath='{.data.root_token}' | base64 -d"
echo ""
echo "💡 Tips:"
echo "   - Re-run this script anytime — healthy components are skipped"
echo "   - Force full redeploy: FORCE_REDEPLOY=1 $0"
echo "   - Skip image builds: SKIP_LOCAL_BUILD=1 $0"
echo "   - Monitor ArgoCD apps: kubectl get applications -n argocd"
echo "   - View logs: kubectl logs -n <namespace> <pod-name>"
echo ""
