#!/bin/bash

# Install all needed components regardless of what pluggable options are used

set -euo pipefail

# DOMAIN can be supplied as the first argument, or auto-detected from the
# OpenShift cluster ingress config (ingresses.config.openshift.io/cluster).
if [ -n "${1:-}" ]; then
  DOMAIN="$1"
else
  DOMAIN=$(kubectl get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  if [ -z "${DOMAIN}" ]; then
    echo "❌ Error: DOMAIN could not be auto-detected and was not provided as an argument."
    echo ""
    echo "Usage: $0 [DOMAIN]"
    echo ""
    echo "Examples:"
    echo "  $0                       # Auto-detect from OpenShift ingress config"
    echo "  $0 localhost             # For local testing"
    echo "  $0 example.com          # Override with explicit domain"
    echo ""
    exit 1
  fi
  echo "ℹ️  Auto-detected DOMAIN from OpenShift ingress config: ${DOMAIN}"
fi
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"


# TODO: Replace the list of apps with oci URI instead of local
# https://gitea.silogen-demo.silogen.ai/cluster-org/cluster-forge/src/branch/main/root/values.yaml
# AIWB_RELEASE_VERSION_TAG=2.0.0

# NOTE: anyuid SCC grants are no longer applied per-namespace here. They are
# consolidated as declarative ClusterRoleBinding manifests in extra/scc.yaml,
# applied up front (see "Applying custom SecurityContextConstraints" below).

# ============================================================================
# RESILIENCE HELPERS (for busy / slow API servers)
# ============================================================================
# On heavily-loaded clusters the API server intermittently returns
# "the server was unable to return a response in the time allotted" or TLS
# handshake timeouts. With `set -e` a single such blip aborts the whole install.
# These helpers give the API server more time per request (--request-timeout)
# and retry transient failures with a backoff instead of aborting.
RETRY_MAX="${RETRY_MAX:-6}"
RETRY_DELAY="${RETRY_DELAY:-15}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-300s}"

# retry <command...> : run a command, retrying on failure with a fixed backoff.
retry() {
  local n=1 rc=0
  while true; do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if (( n >= RETRY_MAX )); then
      echo "❌ command failed after ${RETRY_MAX} attempts (rc=${rc}): $*" >&2
      return "${rc}"
    fi
    echo "⚠️  attempt ${n}/${RETRY_MAX} failed (rc=${rc}); retrying in ${RETRY_DELAY}s..." >&2
    sleep "${RETRY_DELAY}"
    ((n++))
  done
}

# ssa_apply [extra kubectl args...] : server-side apply from stdin with a long
# request timeout and retries. Captures stdin so each retry re-feeds the same
# manifests (a plain `| kubectl apply` cannot be retried once stdin is consumed).
# --force-conflicts: many objects on this cluster still carry stale managedFields
# ownership from a removed ArgoCD (managers argocd-application-controller /
# argocd-controller) and from openshift-controller. Without forcing, server-side
# apply fails with "Apply failed with N conflicts". Since ArgoCD is gone, we are
# the legitimate manager and take ownership of those orphaned fields.
ssa_apply() {
  local manifests n=1 rc=0
  manifests="$(cat)"
  while true; do
    if printf '%s' "${manifests}" | kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" "$@" -f -; then
      return 0
    else
      rc=$?
    fi
    if (( n >= RETRY_MAX )); then
      echo "❌ server-side apply failed after ${RETRY_MAX} attempts (rc=${rc})" >&2
      return "${rc}"
    fi
    echo "⚠️  apply attempt ${n}/${RETRY_MAX} failed (rc=${rc}); retrying in ${RETRY_DELAY}s..." >&2
    sleep "${RETRY_DELAY}"
    ((n++))
  done
}

# kwait <kubectl wait args...> : kubectl wait with retries (the API server can
# time out the watch request itself on a busy cluster, independent of readiness).
kwait() {
  retry kubectl wait --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" "$@"
}

# strip_kind <Kind> : read a stream of "---"-separated YAML docs on stdin and
# drop any document whose top-level "kind:" equals <Kind>. Used to remove chart
# resources we intentionally replace — e.g. the seaweedfs-config OpenBao-backed
# ExternalSecrets, since this standalone installer creates those Secrets from env
# instead (see the SEAWEEDFS section).
strip_kind() {
  local drop="$1"
  awk -v drop="${drop}" '
    function flush() { if (keep) printf "%s", buf; buf=""; keep=1 }
    { sub(/\r$/, "") }                       # tolerate CRLF line endings
    /^---[[:space:]]*$/ { flush(); print "---"; next }
    { buf = buf $0 "\n" }
    $1 == "kind:" && $2 == drop { keep=0 }
    END { flush() }
  '
}

# step <description> : print a numbered banner for the next install phase. The
# counter increments at runtime, so the output shows exactly which phases were
# reached (and in what order) — handy for following / resuming a long install.
STEP=0
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "════════════════ [STEP ${STEP}] $* ════════════════"
}

# detect_amd_gpu_ns : print the namespace where the AMD GPU operator
# controller-manager runs (or will run), regardless of install method. The Helm
# chart names it "amd-gpu-operator-gpu-operator-charts-controller-manager"
# (namespace amd-gpu-operator), while the OpenShift OLM-certified operator names
# it "amd-gpu-operator-controller-manager" (e.g. openshift-amd-gpu). The
# namespace is therefore unpredictable; we look it up at runtime and fall back
# to "amd-gpu-operator" (where this script installs the operator on a clean
# cluster). The operator and its DeviceConfig MUST share this namespace, and the
# otel collector's GPU scrape job must target it too.
detect_amd_gpu_ns() {
  local ns
  ns=$(kubectl get deploy -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '/amd-gpu-operator.*controller-manager/ {print $1; exit}' || true)
  printf '%s' "${ns:-amd-gpu-operator}"
}

# ensure_extra_file <abs_path_under_docs/aiwb_on_openshift/extra> : make sure an
# extra/ manifest exists locally, fetching it from the test-aiwb branch if the
# cloned branch does not include it yet. (Same WORKAROUND used for scc.yaml,
# routes.yaml, kyverno-scc-for-ns.yaml — remove once these are merged to main.)
ensure_extra_file() {
  local f="$1" base
  base="$(basename "${f}")"
  if [ ! -f "${f}" ]; then
    echo "ℹ️  ${base} not in cloned branch '${CLUSTER_FORGE_BRANCH}'; fetching from test-aiwb..."
    mkdir -p "$(dirname "${f}")"
    retry curl -fsSL \
      "https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/extra/${base}" \
      -o "${f}"
  fi
}

PLUGGABLE_DB=${PLUGGABLE_DB:-false}
PLUGGABLE_S3=${PLUGGABLE_S3:-false}

CNPG_INSTANCES=1

# Rancher Desktop has "local-path", most environments use "default"
DEFAULT_STORAGE_CLASS_NAME="${DEFAULT_STORAGE_CLASS_NAME:-default}"

# External PostgreSQL config — used only when PLUGGABLE_DB=true to point AIWB
# and Keycloak at a user-supplied database instead of the in-cluster CNPG cluster.
# User must have created the databases and roles before running this script
# (see components/db.md for instructions).
POSTGRES_HOST="${POSTGRES_HOST:-host.docker.internal}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
AIWB_DB_NAME="${AIWB_DB_NAME:-aiwb}"
AIWB_DB_USER="${AIWB_DB_USER:-aiwb_user}"
AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloak}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"
# CNPG superuser credentials — used only in PLUGGABLE_DB=false mode to populate
# the aiwb-cnpg-superuser / keycloak-cnpg-superuser Secrets that the CNPG
# Cluster spec references. Unused by application pods; default to placeholder.
AIWB_CNPG_SUPERUSER_USER="${AIWB_CNPG_SUPERUSER_USER:-placeholder}"
AIWB_CNPG_SUPERUSER_PASSWORD="${AIWB_CNPG_SUPERUSER_PASSWORD:-placeholder}"
KEYCLOAK_CNPG_SUPERUSER_USER="${KEYCLOAK_CNPG_SUPERUSER_USER:-placeholder}"
KEYCLOAK_CNPG_SUPERUSER_PASSWORD="${KEYCLOAK_CNPG_SUPERUSER_PASSWORD:-placeholder}"
# Secret names used in pluggable mode (chart defaults are aiwb-cnpg-user /
# keycloak-cnpg-user; we use db-suffixed names to make the source obvious).
AIWB_DB_SECRET_NAME="aiwb-db-user"
KEYCLOAK_DB_SECRET_NAME="keycloak-db-user"

# External MinIO config — used only when PLUGGABLE_S3=true. AIWB is pointed
# at the external endpoint via --set minio.url / minio.bucket below, and an
# in-cluster redirect Service is created so that consumers that hardcode the
# in-cluster MinIO URL (e.g. aim-performance's BUCKET_STORAGE_HOST) reach the
# external storage transparently.
MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
# Host port external MinIO publishes its S3 API on. Default 9999 matches the
# minio-byo container layout used in this dev workflow (container :9000 → host :9999).
MINIO_PORT="${MINIO_PORT:-9999}"
# IP that backs the redirect Endpoints. Defaults to the Rancher Desktop host IP.
# Override with MINIO_HOST_IP=<ip> for other engines (kind, minikube, etc.).
MINIO_HOST_IP="${MINIO_HOST_IP:-192.168.127.254}"
MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
# MinIO credentials. In PLUGGABLE_S3=false mode these populate the in-cluster
# MinIO Tenant `default-user` Secret AND the `minio-credentials` Secret that
# AIWB / workbench pods authenticate with — the API_* values must match on
# both sides. In PLUGGABLE_S3=true mode the API_* values are written into
# `minio-credentials` so AIWB can talk to the external MinIO; the CONSOLE_*
# values are unused in that mode (no in-cluster Tenant). Defaults are
# placeholders — replace for any non-dev deployment. The `s3_minio_container.sh`
# helper prints the matching values for its own dev container workflow.
MINIO_API_ACCESS_KEY="${MINIO_API_ACCESS_KEY:-placeholder}"
MINIO_API_SECRET_KEY="${MINIO_API_SECRET_KEY:-placeholder}"
MINIO_CONSOLE_ACCESS_KEY="${MINIO_CONSOLE_ACCESS_KEY:-placeholder}"
MINIO_CONSOLE_SECRET_KEY="${MINIO_CONSOLE_SECRET_KEY:-placeholder}"
# Leave empty to auto-detect the node's internal IP at install time (recommended for cloud VMs).
# Override with e.g. METALLB_IP_RANGE=10.0.1.5-10.0.1.10 for a dedicated pool.
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"

# Derive protocol-aware URL bases from DOMAIN.
# For a real domain the gateway uses HTTPS with subdomain routing;
# for localhost it uses plain HTTP on fixed ports (overridden by post_install.sh).
if [ "${DOMAIN}" = "localhost" ]; then
  KC_HOSTNAME="http://localhost:8080"
  KC_URL="http://localhost:8080"
  AIWB_UI_URL="http://localhost:8000"
else
  KC_HOSTNAME="https://kc.${DOMAIN}"
  KC_URL="https://kc.${DOMAIN}"
  AIWB_UI_URL="https://aiwbui.${DOMAIN}"
fi

# Download a pinned cluster-forge release tarball instead of cloning a branch.
# CLUSTER_FORGE_VERSION selects the GitHub release (e.g. v2.2.0). The release
# asset "release-enterprise-ai-<version>.tar.gz" unpacks into a top-level
# "cluster-forge/" directory that contains root/, scripts/ and sources/ — but
# NOT docs/. Files that used to live under docs/ are therefore sourced elsewhere:
#   - aiwb_on_openshift/extra/*  -> vendored locally next to this script (EXTRA_DIR)
#   - manual_helm_install/*      -> fetched from the matching git tag (MANUAL_HELM_DIR)
CLUSTER_FORGE_VERSION="${CLUSTER_FORGE_VERSION:-v2.2.0}"
CLUSTER_FORGE_DIR="${CLUSTER_FORGE_DIR:-/tmp/cluster-forge}"
# Branch used only by the legacy "fetch from GitHub" fallbacks for extra/ files
# (kept for backward compatibility; local vendored copies are preferred).
CLUSTER_FORGE_BRANCH="${CLUSTER_FORGE_BRANCH:-main}"

RELEASE_TARBALL="release-enterprise-ai-${CLUSTER_FORGE_VERSION}.tar.gz"
RELEASE_URL="https://github.com/silogen/cluster-forge/releases/download/${CLUSTER_FORGE_VERSION}/${RELEASE_TARBALL}"

step "Downloading cluster-forge release ${CLUSTER_FORGE_VERSION}"
rm -rf "${CLUSTER_FORGE_DIR}"
mkdir -p "${CLUSTER_FORGE_DIR}"
retry wget -q -O "${CLUSTER_FORGE_DIR}/${RELEASE_TARBALL}" "${RELEASE_URL}"
tar -xzf "${CLUSTER_FORGE_DIR}/${RELEASE_TARBALL}" -C "${CLUSTER_FORGE_DIR}"
rm -f "${CLUSTER_FORGE_DIR}/${RELEASE_TARBALL}"

# The tarball unpacks under ${CLUSTER_FORGE_DIR}/cluster-forge; sources live there.
SOURCES_DIR="${CLUSTER_FORGE_DIR}/cluster-forge/sources"

# extra/ manifests (SCC, routes, kyverno policies, NFR) are vendored next to this
# script. Override EXTRA_DIR to point elsewhere if needed.
EXTRA_DIR="${EXTRA_DIR:-${SCRIPT_DIR}/extra}"

# manual_helm_install files (AIWB secrets + cluster-auth shim) are NOT shipped in
# the release tarball, so fetch them from the matching git tag into a staging dir.
MANUAL_HELM_DIR="${CLUSTER_FORGE_DIR}/manual_helm_install"
MANUAL_HELM_RAW_BASE="https://raw.githubusercontent.com/silogen/cluster-forge/${CLUSTER_FORGE_VERSION}/docs/manual_helm_install"
echo "📥 Fetching manual_helm_install files from tag ${CLUSTER_FORGE_VERSION}..."
mkdir -p "${MANUAL_HELM_DIR}/secrets" "${MANUAL_HELM_DIR}/scripts"
retry curl -fsSL "${MANUAL_HELM_RAW_BASE}/secrets/secrets-aiwb.yaml"            -o "${MANUAL_HELM_DIR}/secrets/secrets-aiwb.yaml"
retry curl -fsSL "${MANUAL_HELM_RAW_BASE}/secrets/secrets-aiwb-standalone.yaml" -o "${MANUAL_HELM_DIR}/secrets/secrets-aiwb-standalone.yaml"
retry curl -fsSL "${MANUAL_HELM_RAW_BASE}/scripts/cluster-auth-shim.py"         -o "${MANUAL_HELM_DIR}/scripts/cluster-auth-shim.py"
echo "✅ Sources extracted to ${SOURCES_DIR}"

# ============================================================================
# POST-CLONE PATCHES
# Apply fixes to cloned sources that have not yet been merged upstream.
# ============================================================================

# Fix: SecurityPolicy extAuth.failOpen must be true for standalone installs.
# Without this, Envoy returns HTTP 500 on every request because it cannot reach
# the gRPC ext-auth service on port 50051 (cluster-auth shim is REST on 8081).
EXTAUTH_TPL="${SOURCES_DIR}/envoy-gateway-config/templates/security-policy-extauth.yaml"
if ! grep -q "failOpen" "${EXTAUTH_TPL}" 2>/dev/null; then
  sed -i 's/  extAuth:/  extAuth:\n    failOpen: true/' "${EXTAUTH_TPL}"
  echo "✅ Patched envoy-gateway-config SecurityPolicy: failOpen=true"
fi

# ============================================================================
# CUSTOM SECURITY CONTEXT CONSTRAINTS (OpenShift)
# ============================================================================
step "Custom SecurityContextConstraints (SCCs)"
# Some components ship pods that the generic `anyuid` SCC cannot admit — e.g.
# the OpenTelemetry operator sets seccompProfile: RuntimeDefault, which `anyuid`
# (empty seccompProfiles) rejects, so its Deployment never produces a pod
# (ReplicaFailure: FailedCreate). Apply the project's custom SCCs up front so
# they exist before any workload pod is scheduled. SCC `users` entries may point
# at service accounts that do not exist yet — that is fine; the binding takes
# effect once the SA is created.
SCC_FILE="${EXTRA_DIR}/scc.yaml"
echo "📦 Applying custom SecurityContextConstraints..."
# WORKAROUND: the sources clone above uses ${CLUSTER_FORGE_BRANCH} (default
# "main"), but scc.yaml currently only lives on the test-aiwb branch. If it is
# missing from the clone, copy it in from the test-aiwb branch so the apply
# works regardless of which branch was cloned. (Remove once scc.yaml is merged.)
if [ ! -f "${SCC_FILE}" ]; then
  echo "ℹ️  scc.yaml not in cloned branch '${CLUSTER_FORGE_BRANCH}'; fetching from test-aiwb..."
  mkdir -p "$(dirname "${SCC_FILE}")"
  retry curl -fsSL \
    https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/extra/scc.yaml \
    -o "${SCC_FILE}"
fi
retry kubectl apply --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f "${SCC_FILE}"
echo "✅ Custom SCCs applied"

# ============================================================================
# LOCAL-PATH PROVISIONER & DEFAULT STORAGE CLASS
# ============================================================================
step "local-path provisioner & default StorageClass"
# RKE2 ships with rancher.io/local-path provisioner built-in, but may not have
# a StorageClass named "default" or a cluster-default class set. PVCs that
# request storageClass "default" (or leave it empty) will stay Pending without this.

# Install upstream local-path-provisioner only if the local-path StorageClass
# is missing entirely (e.g. on a non-RKE2 cluster).
if kubectl get storageclass local-path &>/dev/null; then
  echo "ℹ️  local-path StorageClass already exists — skipping provisioner install"
else
  echo "📦 Installing local-path provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  echo "⏳ Waiting for local-path provisioner to be ready..."
  kwait --for=condition=available --timeout=120s deployment/local-path-provisioner -n local-path-storage
  echo "✅ local-path provisioner is ready"
fi

# Ensure a StorageClass named "default" exists and is the cluster default.
# Uses rancher.io/local-path which is always present on RKE2.
if kubectl get storageclass default &>/dev/null; then
  echo "ℹ️  default StorageClass already exists"
else
  echo "📦 Creating default StorageClass (rancher.io/local-path)..."
  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
  echo "✅ default StorageClass created"
fi

# Make sure exactly one class is marked as the cluster default.
# If no class has the annotation set to "true", annotate "default".
if ! kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' \
    2>/dev/null | tr ' ' '\n' | grep -q "^true$"; then
  kubectl patch storageclass default -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  echo "✅ default StorageClass marked as cluster default"
fi
echo ""

# ============================================================================
# Installing main apps
# Using the parms from demo reference at: https://gitea.silogen-demo.silogen.ai/cluster-org/cluster-forge/raw/branch/main/root/values.yaml

# ============================================================================
# KUBERAY OPERATOR
# ============================================================================
step "Kuberay operator"
echo "📦 Installing Kuberay operator..."
helm template kuberay-operator ${SOURCES_DIR}/kuberay-operator/1.4.2 --namespace default | ssa_apply

# ============================================================================
# DATABASE OPERATOR (CloudNativePG)
# ============================================================================
step "CloudNativePG database operator"
# CNPG Cluster CRD is required for Keycloak and AIWB database templates when
# PLUGGABLE_DB=false (the default).
if [[ ${PLUGGABLE_DB} != true ]]; then
  echo "📦 Installing CloudNativePG operator..."
  kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f -
  helm template cnpg-operator ${SOURCES_DIR}/cnpg-operator/0.26.0 --namespace cnpg-system | ssa_apply

  echo "⏳ Waiting for CNPG operator to be ready..."
  kwait --for=condition=available --timeout=120s deployment/cnpg-operator-cloudnative-pg -n cnpg-system
  echo "✅ CloudNativePG is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for CloudNativePG as it's going to be removed later."
fi

# ============================================================================
# Appwrapper
# ============================================================================
step "Appwrapper"
kubectl create namespace appwrapper-system --dry-run=client -o yaml | kubectl apply -f -
retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/appwrapper/v1.1.2 --namespace appwrapper-system

# ============================================================================
# KYVERNO (Policy Management)
# ============================================================================
step "Kyverno (policy management)"
# syncWave: -40
# Install Kyverno for policy management (required for storage policies)
echo "📦 Installing Kyverno..."
kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
# Disable webhooksCleanup to prevent pre-delete hooks from running during helm template | kubectl apply.
# Raise reports-controller memory: on OpenShift it watches every cluster resource
# (granted via the cluster-reader binding below), and the default 128Mi limit
# gets OOMKilled, leaving the deployment unavailable.
# --request-timeout=300s: the kyverno clusterpolicies.kyverno.io / policies.kyverno.io
# CRDs have very large schemas. On a busy/slow API server the server-side-apply
# patch of these CRDs can exceed the default request timeout, returning
# "the server was unable to return a response in the time allotted". Allowing up
# to 5 minutes per request gives the API server time to finish the merge.
helm template kyverno ${SOURCES_DIR}/kyverno/3.5.1 --namespace kyverno \
  --set webhooksCleanup.enabled=false \
  --set reportsController.resources.limits.memory=1Gi \
  --set reportsController.resources.requests.memory=256Mi \
  | ssa_apply

# Grant kyverno-reports-controller extra RBAC needed on OpenShift BEFORE waiting.
# Kyverno's reports-controller discovers and watches every API resource in the
# cluster. On OpenShift this includes many platform-specific resources
# (MachineConfigPool, MachineConfiguration, MachineConfigNode, etc.) that the
# default Kyverno ClusterRole does not cover, causing a crash loop.
# Binding the OpenShift built-in cluster-reader ClusterRole gives read access
# to all resources in one shot without granting write permissions.
# This must be applied before the wait so the pod can start cleanly.
echo "📦 Applying OpenShift RBAC patch for kyverno-reports-controller..."
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno-reports-controller-cluster-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-reader
subjects:
- kind: ServiceAccount
  name: kyverno-reports-controller
  namespace: kyverno
EOF
echo "✅ OpenShift RBAC patch applied"

# Wait for Kyverno to be ready
echo "⏳ Waiting for Kyverno to be ready..."
kwait --for=condition=available --timeout=120s deployment/kyverno-admission-controller -n kyverno
kwait --for=condition=available --timeout=120s deployment/kyverno-background-controller -n kyverno
kwait --for=condition=available --timeout=120s deployment/kyverno-cleanup-controller -n kyverno
kwait --for=condition=available --timeout=120s deployment/kyverno-reports-controller -n kyverno
echo "✅ Kyverno is ready"
echo ""

# ============================================================================
# KYVERNO POLICIES
# ============================================================================
step "Kyverno base + storage policies"
# syncWave: -30
# Install Kyverno policies for base security and storage management
echo "📦 Installing Kyverno base policies..."
helm template kyverno-policies-base ${SOURCES_DIR}/kyverno-policies/base --namespace kyverno | ssa_apply

echo "📦 Installing Kyverno storage-local-path policies..."
helm template kyverno-policies-storage ${SOURCES_DIR}/kyverno-policies/storage-local-path --namespace kyverno | ssa_apply

echo "✅ Kyverno policies installed"
echo ""

# ============================================================================
# EXTRA OPENSHIFT KYVERNO POLICIES
# ============================================================================
step "Extra OpenShift Kyverno policies (SCC + HTTPRoute->Route)"
# generate-scc-on-namespaces: auto-generates a per-project OpenShift SCC for any
# Namespace labelled airm.silogen.ai/project-id. The RBAC that lets Kyverno
# manage SecurityContextConstraints (the kyverno-scc-generator ClusterRole and
# binding) is applied earlier from extra/scc.yaml, so by now it already exists.
echo "📦 Installing extra OpenShift Kyverno policies..."
# EXTRA_DIR is defined once near the top (defaults to the extra/ dir beside this script).
KYVERNO_SCC_POLICY_FILE="${EXTRA_DIR}/kyverno-scc-for-ns.yaml"
ensure_extra_file "${KYVERNO_SCC_POLICY_FILE}"
ssa_apply < "${KYVERNO_SCC_POLICY_FILE}"

# HTTPRoute -> OpenShift Route automation. AIWB exposes workspace apps via
# Gateway API HTTPRoutes (labelled airm.silogen.ai/workload-id). On OpenShift
# there is no Gateway controller serving them, so these Kyverno policies watch
# those HTTPRoutes and generate a matching OpenShift Route automatically.
#   1. RBAC first  — lets the Kyverno admission/background controllers manage
#      Routes (incl. routes/custom-host, required to set spec.host).
#   2. Policies    — the non-rewrite + rewrite variants. They hard-code the host
#      as "workloads.<DOMAIN>", so substitute the real cluster domain on the fly
#      (local apply-time patch; sources/extra files stay branch-default).
echo "📦 Installing HTTPRoute->Route Kyverno policies..."
# OpenShift's default route admission is "Strict": a Route in one namespace
# cannot claim a hostname already owned by a Route in another namespace. The
# policies below generate workspace Routes on the AIWB UI host (aiwbui.<DOMAIN>,
# owned by the aiwb namespace) under distinct /workbench/<...> paths, but those
# Routes live in the per-workspace namespaces (e.g. workbench). Without this they
# are rejected with "HostAlreadyClaimed". InterNamespaceAllowed permits sharing a
# host across namespaces (path-based), which is exactly what AIWB needs.
echo "🔧 Allowing inter-namespace route host sharing (workspace Routes share the AIWB UI host)..."
retry kubectl patch ingresscontroller default -n openshift-ingress-operator --type=merge \
  -p '{"spec":{"routeAdmission":{"namespaceOwnership":"InterNamespaceAllowed"}}}'
KYVERNO_ROUTE_RBAC_FILE="${EXTRA_DIR}/kyverno-route-permissions.yaml"
KYVERNO_ROUTE_POLICY_FILE="${EXTRA_DIR}/kyverno-httproute-to-route-non-rewrite-policy.yaml"
KYVERNO_ROUTE_REWRITE_POLICY_FILE="${EXTRA_DIR}/kyverno-httproute-to-route-rewrite-policy.yaml"
ensure_extra_file "${KYVERNO_ROUTE_RBAC_FILE}"
ensure_extra_file "${KYVERNO_ROUTE_POLICY_FILE}"
ensure_extra_file "${KYVERNO_ROUTE_REWRITE_POLICY_FILE}"
# RBAC must exist before the generate policies so Kyverno can create Routes.
ssa_apply < "${KYVERNO_ROUTE_RBAC_FILE}"
sed "s|<DOMAIN>|${DOMAIN}|g" "${KYVERNO_ROUTE_POLICY_FILE}" | ssa_apply
sed "s|<DOMAIN>|${DOMAIN}|g" "${KYVERNO_ROUTE_REWRITE_POLICY_FILE}" | ssa_apply

# Orphaned-SCC garbage collector: companion to kyverno-scc-for-ns.yaml. A
# ClusterCleanupPolicy (+ GlobalContextEntry) that runs every minute and deletes
# per-project SCCs whose source namespace is gone or was recreated with a
# different UID, so generated SCCs do not accumulate over the cluster's lifetime.
# Requires the Kyverno cleanup controller to be enabled.
echo "🧹 Installing orphaned-SCC cleanup policy..."
KYVERNO_CLEANUP_POLICY_FILE="${EXTRA_DIR}/kyverno-cleanup-policy.yaml"
ensure_extra_file "${KYVERNO_CLEANUP_POLICY_FILE}"
ssa_apply < "${KYVERNO_CLEANUP_POLICY_FILE}"

echo "✅ Extra OpenShift Kyverno policies installed"
echo ""

# ============================================================================
# STORAGE CLASSES
# ============================================================================
step "Workspace StorageClasses (multinode, mlstorage)"
# Create multinode and mlstorage StorageClasses for workspace PVCs.
# Skip each one if it already exists — the provisioner field is immutable
# so applying over an existing class with a different provisioner would fail.
echo "📦 Creating storage classes..."
if kubectl get storageclass multinode &>/dev/null; then
  echo "ℹ️  multinode StorageClass already exists — skipping"
else
  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: multinode
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
fi

if kubectl get storageclass mlstorage &>/dev/null; then
  echo "ℹ️  mlstorage StorageClass already exists — skipping"
else
  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mlstorage
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
fi
echo "✅ Storage classes ready"
echo ""

# ============================================================================
# PROMETHEUS CRDs
# ============================================================================
step "Prometheus Operator CRDs"
# syncWave: -50
# Prometheus Operator CRDs required by monitoring components.
# On OpenShift, the cluster-version-operator already manages these CRDs
# (alertmanagers.monitoring.coreos.com etc.), so we skip if they are present.
if kubectl get crd alertmanagers.monitoring.coreos.com &>/dev/null; then
  echo "ℹ️  Prometheus Operator CRDs already present (managed by cluster) — skipping install"
else
  echo "📦 Installing Prometheus Operator CRDs..."
  kubectl create namespace prometheus-system --dry-run=client -o yaml | kubectl apply -f -
  helm template prometheus-crds ${SOURCES_DIR}/prometheus-operator-crds/23.0.0 --namespace prometheus-system | ssa_apply
fi

echo "✅ Prometheus CRDs ready"
echo ""

# ============================================================================
# CERT-MANAGER
# ============================================================================
step "cert-manager"
# syncWave: -30
# Required by OpenTelemetry Operator and KServe for webhook certificates
echo "📦 Installing cert-manager..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm template cert-manager ${SOURCES_DIR}/cert-manager/v1.18.2 --namespace cert-manager --set crds.enabled=true | ssa_apply

# Wait for cert-manager to be ready (required for webhooks)
echo "⏳ Waiting for cert-manager deployments to be ready..."
kwait --for=condition=available --timeout=120s \
  deployment/cert-manager-webhook \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  -n cert-manager

# Wait for cert-manager webhook to have valid certificates (can take 10-30 seconds)
echo "⏳ Waiting for cert-manager webhook certificates to be ready..."
sleep 1
until kubectl get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; do
  echo "  Still waiting for webhook CA bundle..."
  sleep 5
done
echo "✅ cert-manager is ready"
echo ""

# ============================================================================
# OPENTELEMETRY OPERATOR & METALLB (parallel install)
# ============================================================================
step "OpenTelemetry operator"
# syncWave: -25 (OpenTelemetry), 10 (MetalLB)
# These components are independent and can be installed in parallel

echo "📦 Installing OpenTelemetry Operator..."
kubectl create namespace opentelemetry-system --dry-run=client -o yaml | kubectl apply -f -
helm template opentelemetry-operator ${SOURCES_DIR}/opentelemetry-operator/0.93.1 --namespace opentelemetry-system --include-crds | ssa_apply

echo "⏭️  Skipping MetalLB installation (OpenShift provides its own load balancer/routing)"

echo "⏳ Waiting for OpenTelemetry Operator to be ready..."
until kubectl get deployment opentelemetry-operator -n opentelemetry-system >/dev/null 2>&1; do
  sleep 1
done
kwait --for=condition=available --timeout=120s deployment/opentelemetry-operator -n opentelemetry-system

echo "✅ OpenTelemetry Operator and MetalLB are ready"
echo ""



# ============================================================================
# EXTERNAL SECRETS OPERATOR
# ============================================================================
step "External Secrets Operator"
# Required by otel-lgtm-stack (grafana-admin-credentials ExternalSecret) and
# other components that pull secrets from an external store.
echo "📦 Installing External Secrets Operator..."
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
helm template external-secrets ${SOURCES_DIR}/external-secrets/0.19.2 \
  --namespace external-secrets \
  | ssa_apply

echo "⏳ Waiting for External Secrets Operator to be ready..."
kwait --for=condition=available --timeout=120s deployment/external-secrets -n external-secrets
kwait --for=condition=available --timeout=120s deployment/external-secrets-webhook -n external-secrets

echo "⏳ Waiting for External Secrets CRDs to be established..."
kwait --for=condition=established --timeout=60s \
  crd/externalsecrets.external-secrets.io \
  crd/secretstores.external-secrets.io \
  crd/clustersecretstores.external-secrets.io
echo "✅ External Secrets Operator is ready"

# Bust kubectl API discovery cache so the newly installed CRDs are visible
# to subsequent kubectl apply calls (stale cache causes "no matches for kind" errors)
rm -rf "${HOME}/.kube/cache/discovery"
echo ""

# ============================================================================
# GATEWAY API CRDs (early)
# ============================================================================
step "Gateway API CRDs"
# Several components (openbao-config, otel-lgtm-stack) render HTTPRoute resources
# (gateway.networking.k8s.io/v1) that fail to apply unless the Gateway API CRDs
# already exist. Envoy Gateway is the Gateway API implementation (see the ENVOY
# GATEWAY section below); its chart bundles both the upstream Gateway API CRDs and
# the envoy-specific CRDs. We install all of them early so those HTTPRoutes apply
# cleanly. Idempotent — installed via --server-side so the later controller install
# co-owns them without conflict.
# SKIP_GATEWAY_API_CRDS: on OpenShift the Gateway API CRDs are provided by the
# platform, so installing them here is unnecessary and just re-triggers stale
# managedFields conflicts. Default to skipping; set SKIP_GATEWAY_API_CRDS=false
# to install them (e.g. on a cluster that does not ship Gateway API).
if [ "${SKIP_GATEWAY_API_CRDS:-true}" = "true" ]; then
  echo "⏭️  Skipping Gateway API CRDs install (not needed on OpenShift)"
else
  echo "📦 Installing Gateway API CRDs (early)..."
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/envoy-gateway/v1.7.1/crds/gatewayapi-crds.yaml
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/envoy-gateway/v1.7.1/crds/generated/

  echo "⏳ Waiting for Gateway API HTTPRoute CRD to be established..."
  kwait --for=condition=established --timeout=60s \
    crd/httproutes.gateway.networking.k8s.io \
    crd/gateways.gateway.networking.k8s.io

  # Bust kubectl discovery cache so the newly installed Gateway API kinds are visible
  rm -rf "${HOME}/.kube/cache/discovery"
  echo "✅ Gateway API CRDs installed"
fi
echo ""

# ============================================================================
# OPENBAO (Secrets Management)
# ============================================================================
step "OpenBao (secrets management)"
# Required by otel-lgtm-stack and other components that use ExternalSecret
# resources pointing at openbao-secret-store ClusterSecretStore.
echo "📦 Installing OpenBao..."
kubectl create namespace cf-openbao --dry-run=client -o yaml | kubectl apply -f -

helm template openbao ${SOURCES_DIR}/openbao/0.18.2 \
  --namespace cf-openbao \
  | ssa_apply

echo "⏳ Waiting for OpenBao pod to be Running (init job will initialize and unseal it)..."
until kubectl get pod openbao-0 -n cf-openbao -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; do
  echo "  Still waiting for openbao-0 to start..."
  sleep 5
done
echo "  openbao-0 is Running"

# Apply OpenBao config: secret definitions ConfigMap + HTTPRoute for UI
echo "📦 Applying OpenBao config..."
helm template openbao-config ${SOURCES_DIR}/openbao-config/0.1.0 \
  --namespace cf-openbao \
  --set domain="${DOMAIN}" \
  --set minio.apiAccessKey="${MINIO_API_ACCESS_KEY}" \
  --set minio.consoleAccessKey="${MINIO_CONSOLE_ACCESS_KEY}" \
  | kubectl apply -f - || true

# The init job references ConfigMaps with an -init suffix, but the openbao-config chart
# creates them without that suffix. Create aliases with the expected names.
echo "📦 Creating -init ConfigMap aliases for the init job..."
for cm_pair in "openbao-secrets-config:openbao-secrets-init-config" "openbao-secret-manager-scripts:openbao-secret-manager-scripts-init"; do
  src="${cm_pair%%:*}"
  dst="${cm_pair##*:}"
  kubectl get configmap "${src}" -n cf-openbao -o json \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['metadata']['name'] = '${dst}'
for k in ['resourceVersion', 'uid', 'creationTimestamp', 'generation', 'managedFields']:
    d['metadata'].pop(k, None)
print(json.dumps(d))
" | kubectl apply -f -
done

# Apply OpenBao init job: initialises + unseals OpenBao, creates secrets, sets up auth
echo "📦 Running OpenBao init job..."
helm template openbao-init-job ${SOURCES_DIR}/openbao-init-job/0.1.0 \
  --namespace cf-openbao \
  --set domain="${DOMAIN}" \
  | kubectl apply -f -

echo "⏳ Waiting for OpenBao init job to complete (up to 5 min)..."
kwait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao

# Apply ClusterSecretStore so ExternalSecrets can pull from OpenBao.
# The repo manifests target external-secrets.io/v1beta1, but the pinned ESO
# version (0.19.2) only serves v1 (v1beta1 is no longer served). The spec is
# identical between the two, so we rewrite the apiVersion on the fly.
echo "📦 Applying OpenBao ClusterSecretStore..."
sed 's#external-secrets.io/v1beta1#external-secrets.io/v1#g' \
  ${SOURCES_DIR}/external-secrets-config/openbao-secret-store.yaml \
  | kubectl apply -f -

echo "⏳ Waiting for ClusterSecretStore to be ready..."
until kubectl get clustersecretstore openbao-secret-store -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; do
  echo "  Still waiting for ClusterSecretStore..."
  sleep 5
done

echo "✅ OpenBao is ready"
echo ""

# ============================================================================
# OTEL LGTM STACK (Observability)
# ============================================================================
step "OTEL LGTM stack (Grafana/Loki/Tempo/Prometheus)"
# syncWave: -20
# Complete observability stack: Prometheus, Grafana, Loki, Tempo, Mimir
# Depends on: OpenTelemetry Operator, Prometheus CRDs, External Secrets Operator
echo "📦 Installing OTEL LGTM Stack (Prometheus, Grafana, Loki, Tempo)..."
kubectl create namespace otel-lgtm-stack --dry-run=client -o yaml | kubectl apply -f -

# The otel-collector-metrics-rest scrape config (in sources, kept pristine)
# discovers the AMD GPU metrics exporter pods in the hard-coded upstream default
# namespace "kube-amd-gpu". On this cluster the operator may run elsewhere (e.g.
# openshift-amd-gpu), so that job would find zero targets and no GPU metrics
# (gpu_gfx_activity, ...) would reach Prometheus. Detect the real namespace and
# rewrite it on the fly below — a local, apply-time patch (sources stay default).
AMD_GPU_NS="$(detect_amd_gpu_ns)"
echo "ℹ️  AMD GPU Operator namespace (for otel GPU scrape job): ${AMD_GPU_NS}"

# Use values from cluster-forge with medium-sized resource overrides.
# services.nodeExporter.metrics=9101: the bundled prometheus-node-exporter runs
# with hostNetwork on port 9100, which collides with OpenShift's built-in
# cluster-monitoring node-exporter (also hostNetwork:9100) on every node, leaving
# all node-exporter pods Pending ("didn't have free ports"). Move ours to 9101.
#
# Server-side apply merges container ports by their list key (containerPort +
# protocol), NOT by name. If a previous install left the node-exporter DaemonSet
# on a different metrics port (e.g. 9102), re-applying with 9101 does not replace
# the old entry — SSA keeps BOTH, producing two ports named "metrics" and failing
# with 'ports[1].name: Duplicate value: "metrics"'. Delete the DaemonSet first so
# it is recreated cleanly on the intended port. (--ignore-not-found: no-op on a
# fresh cluster.)
kubectl delete daemonset nodeexporter-prometheus-node-exporter -n otel-lgtm-stack \
  --ignore-not-found --request-timeout="${KUBECTL_REQUEST_TIMEOUT}"
helm template otel-lgtm-stack ${SOURCES_DIR}/otel-lgtm-stack/v1.0.7 \
  --namespace otel-lgtm-stack \
  --set cluster.name="${DOMAIN}" \
  --set collectors.resources.metrics.requests.cpu=500m \
  --set collectors.resources.metrics.requests.memory=1Gi \
  --set collectors.resources.metrics.limits.memory=4Gi \
  --set collectors.resources.logs.requests.cpu=250m \
  --set collectors.resources.logs.requests.memory=256Mi \
  --set collectors.resources.logs.limits.cpu=1 \
  --set collectors.resources.logs.limits.memory=1Gi \
  --set dashboards.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --set nodeExporter.enabled=true \
  --set services.nodeExporter.metrics=9101 \
  --set lgtm.resources.requests.cpu=1 \
  --set lgtm.resources.requests.memory=2Gi \
  --set lgtm.resources.limits.memory=8Gi \
  --set lgtm.storage.grafana=10Gi \
  --set lgtm.storage.loki=50Gi \
  --set lgtm.storage.mimir=50Gi \
  --set lgtm.storage.tempo=50Gi \
  --set lgtm.storage.extra=50Gi \
  | sed 's#external-secrets.io/v1beta1#external-secrets.io/v1#g' \
  | sed "s#kube-amd-gpu#${AMD_GPU_NS}#g" \
  | ssa_apply

# Wait for main LGTM components
echo "⏳ Waiting for LGTM stack to be ready..."
sleep 5
kubectl wait --for=condition=available --timeout=180s deployment -l app.kubernetes.io/name=lgtm -n otel-lgtm-stack 2>/dev/null || echo "⚠️  LGTM deployment check completed"

echo "✅ OTEL LGTM Stack is ready"
echo ""

# ============================================================================
# KEDA (Kubernetes Event-Driven Autoscaling)
# ============================================================================
step "KEDA (event-driven autoscaling)"
# syncWave: -10
# Required by KServe for autoscaling inference workloads
# Depends on: OpenTelemetry Operator (for metrics), cert-manager (for webhooks)
echo "📦 Installing KEDA..."
kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f -
helm template keda ${SOURCES_DIR}/keda/2.18.1 --namespace keda | ssa_apply

# Wait for KEDA operator to be ready
echo "⏳ Waiting for KEDA operator to be ready..."
kwait --for=condition=available --timeout=120s deployment/keda-operator -n keda

# Wait for KEDA metrics server to be ready
echo "⏳ Waiting for KEDA metrics server to be ready..."
kwait --for=condition=available --timeout=120s deployment/keda-operator-metrics-apiserver -n keda

# Wait for KEDA admission webhooks to be ready
echo "⏳ Waiting for KEDA admission webhooks to be ready..."
kwait --for=condition=available --timeout=120s deployment/keda-admission-webhooks -n keda

echo "✅ KEDA is ready"
echo ""

# ============================================================================
# KEDIFY OTEL SCALER
# ============================================================================
step "Kedify OTEL scaler"
# syncWave: -5
# Provides OpenTelemetry metrics integration for KEDA
# Depends on: KEDA
echo "📦 Installing Kedify OTEL Scaler..."
helm template kedify-otel ${SOURCES_DIR}/kedify-otel/v0.0.6 \
  --namespace keda \
  --set validatingAdmissionPolicy.enabled=false \
  | ssa_apply

# Wait for Kedify OTEL scaler to be ready
echo "⏳ Waiting for Kedify OTEL scaler to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/keda-otel-scaler -n keda 2>/dev/null || echo "⚠️  Kedify OTEL scaler deployment check completed"

echo "✅ Kedify OTEL Scaler is ready"
echo ""

# ============================================================================
# METALLB CONFIGURATION — skipped (OpenShift has its own routing)
# ============================================================================
step "MetalLB configuration (skipped on OpenShift)"
echo "⏭️  Skipping MetalLB configuration (not applicable on OpenShift)"
echo ""

# ============================================================================
# ENVOY GATEWAY — skipped (OpenShift provides its own routing via HAProxy/Istio)
# ============================================================================
step "Envoy Gateway (skipped on OpenShift; creating namespaces)"
# On OpenShift, the Kyverno policy "generate-routes-from-httproutes" (installed
# as part of kyverno-policies/base) automatically converts Gateway API HTTPRoute
# resources into OpenShift Routes, so components can create HTTPRoutes as normal
# and OpenShift's router will serve them without a separate Gateway controller.
echo "⏭️  Skipping Envoy Gateway installation (OpenShift: using native routing)"
# FIXME: Still create the namespaces since other components reference them
kubectl create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace cluster-auth --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ============================================================================
# KSERVE
# ============================================================================
step "KServe (model serving)"
# syncWave: -30 (crds), 0 (operator)
# Required for model serving integration with AIM-Engine
# Skip if KServe is already running — e.g. on OpenShift clusters where RHOAI
# manages KServe under redhat-ods-applications. Mirrors the same guard used in
# the OpenShift-specific install script.
kserve_running() {
  local ns="$1"
  local ready
  ready=$(kubectl get deployment -n "${ns}" kserve-controller-manager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ "${ready}" =~ ^[1-9] ]]
}

if kserve_running kserve-system || kserve_running redhat-ods-applications; then
  echo "ℹ️  KServe already installed and running — skipping installation"
  echo "   (detected in kserve-system or redhat-ods-applications)"
else
  echo "📦 Installing KServe CRDs..."
  kubectl create namespace kserve-system --dry-run=client -o yaml | kubectl apply -f -
  helm template kserve-crds ${SOURCES_DIR}/kserve-crds/v0.16.0 --namespace kserve-system | ssa_apply

  echo "📦 Installing KServe operator..."
  # IMPORTANT: cert-manager Certificate resources don't work well with --server-side
  # Apply them separately with regular kubectl apply
  # Set deploymentMode to RawDeployment (default is Knative, which requires Knative Serving)
  kubectl config set-context --current --namespace=kserve-system
  helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
    --namespace kserve-system \
    --set kserve.controller.deploymentMode=RawDeployment \
    | kubectl apply -f - 2>&1 | grep -v "Error from server" || true

  # Wait for certificate to be ready
  echo "⏳ Waiting for KServe webhook certificate to be ready..."
  kwait --for=condition=ready --timeout=60s certificate/serving-cert -n kserve-system

  # Wait for KServe webhook to be ready
  echo "⏳ Waiting for KServe controller to be ready..."
  kwait --for=condition=available --timeout=120s deployment/kserve-controller-manager -n kserve-system

  echo "Applying KServe again to ensure all resources are created (some may fail on first apply due to webhook not being ready)..."
  helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
    --namespace kserve-system \
    --set kserve.controller.deploymentMode=RawDeployment \
    | kubectl apply -f -
  kubectl config set-context --current --namespace=default

  # Wait for webhook endpoints to be available (can take 10-30 seconds after deployment is ready)
  echo "⏳ Waiting for KServe webhook endpoints to be ready..."
  sleep 10
  until kubectl get endpoints kserve-webhook-server-service -n kserve-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
    echo "  Still waiting for webhook endpoints..."
    sleep 5
  done

  # Wait for webhook CA bundle to be injected
  until kubectl get validatingwebhookconfigurations clusterservingruntime.serving.kserve.io -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; do
    echo "  Still waiting for webhook CA bundle..."
    sleep 5
  done

  # FIXME: Maybe check why this is needed 3 times!!!
  # Now re-apply to ensure any resources that failed due to webhook are created
  echo "📦 Re-applying KServe to ensure all resources are created..."
  helm template kserve ${SOURCES_DIR}/kserve/v0.16.0 \
    --namespace kserve-system \
    --set kserve.controller.deploymentMode=RawDeployment \
    | kubectl apply -f - 2>&1 | grep -v "unchanged" | head -20

  # Patch: kserve default cpuLimit of "1" causes InferenceService validation failures when
  # the AIM engine profile sets requests.cpu > 1 (e.g. 4 for throughput-optimised templates).
  # Setting cpuLimit to "" removes the default cap; cpuRequest remains as a scheduling hint.
  kubectl patch configmap inferenceservice-config -n kserve-system --type=merge -p \
    '{"data":{"inferenceService":"{\"resource\":{\"cpuLimit\":\"\",\"cpuRequest\":\"1\",\"memoryLimit\":\"2Gi\",\"memoryRequest\":\"2Gi\"}}"}}'
fi

echo "✅ KServe is ready"
echo ""

# ============================================================================
# AMD GPU OPERATOR
# ============================================================================
step "AMD GPU operator (NFD + KMM + device plugin)"
# syncWave: -10
# Installs Node Feature Discovery (NFD), Kernel Module Management (KMM),
# and the AMD GPU device plugin/metrics exporter.
# Nodes with AMD GPUs are automatically labelled via NFD and the device plugin
# advertises amd.com/gpu resources so workloads can request them.
kubectl create namespace amd-gpu-operator --dry-run=client -o yaml | kubectl apply -f -

if kubectl get crd deviceconfigs.amd.com >/dev/null 2>&1; then
  echo "ℹ️  AMD GPU Operator already installed (deviceconfigs.amd.com CRD present) — skipping"
else
  echo "📦 Installing AMD GPU Operator..."

  # Apply CRDs directly first and wait for them to be established.
  # The GPU operator chart's subchart CRDs (NFD, KMM) must exist in the API server
  # before any pods start, otherwise they crash-loop on missing nodefeatures/nodefeaturegroups.
  # We use kubectl apply rather than helm's CRD handling because helm install with CRDs
  # is not idempotent across re-runs without a pre-existing release.
  # FIXME: Update to latest 1.5.0 amd-gpu-operator chart
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/crds/
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/charts/node-feature-discovery/crds/
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/amd-gpu-operator/v1.4.1/charts/kmm/crds/

  echo "⏳ Waiting for AMD GPU Operator CRDs to be established..."
  kwait --for=condition=established --timeout=60s \
    crd/nodefeatures.nfd.k8s-sigs.io \
    crd/deviceconfigs.amd.com \
    crd/modules.kmm.sigs.x-k8s.io

  # Bust the kubectl discovery cache so the new CRDs are visible to the API server
  rm -rf ~/.kube/cache/discovery
  # Poll until the nodefeatures resource is discoverable via the API (avoids NFD worker crash-loop)
  echo "⏳ Waiting for nodefeatures.nfd.k8s-sigs.io to be discoverable via API..."
  for i in $(seq 1 20); do
    if kubectl get nodefeatures --all-namespaces 2>/dev/null; then
      echo "✅ nodefeatures API is available"
      break
    fi
    echo "  attempt ${i}/20 - not yet available, retrying..."
    sleep 5
  done

  # --no-hooks prevents Helm hook jobs (post-delete, pre-upgrade etc.) from being rendered.
  # Without this, the post-delete hook job "delete-custom-resource-definitions" runs as a
  # regular job and deletes all NFD/KMM CRDs immediately after they are created.
  helm template amd-gpu-operator ${SOURCES_DIR}/amd-gpu-operator/v1.4.1 \
    --namespace amd-gpu-operator \
    --set crds.defaultCR.install=true \
    --skip-crds \
    --no-hooks \
    | ssa_apply -n amd-gpu-operator

  echo "⏳ Waiting for AMD GPU Operator controller to be ready..."
  kwait --for=condition=available --timeout=180s \
    deployment/amd-gpu-operator-gpu-operator-charts-controller-manager -n amd-gpu-operator
  echo "✅ AMD GPU Operator is ready"
fi

# ============================================================================
# AMD GPU OPERATOR CONFIG (DeviceConfig + metrics ConfigMap + RBAC)
# ============================================================================
step "AMD GPU operator config (DeviceConfig)"
# Applied after the operator is running (CRDs must exist). The DeviceConfig MUST
# be created in the same namespace as the operator (see detect_amd_gpu_ns). We
# re-detect here because, on a clean cluster, the operator is installed by the
# section above and its namespace is only certain now.
AMD_GPU_NS="$(detect_amd_gpu_ns)"
echo "ℹ️  AMD GPU Operator namespace: ${AMD_GPU_NS}"

# We only care whether a DeviceConfig already exists ANYWHERE in the cluster
# (regardless of name/namespace). If one exists, the operator is already
# configured and we leave it alone. If none exists, create one in the namespace
# where the GPU operator actually runs (AMD_GPU_NS detected above).
# Guard first on the CRD: kubectl get against a missing CRD errors out (which
# would abort the script), so check the CRD is present before querying.
if ! kubectl get crd deviceconfigs.amd.com >/dev/null 2>&1; then
  echo "⚠️  deviceconfigs.amd.com CRD not found — skipping AMD GPU Operator config"
elif [ -n "$(kubectl get deviceconfigs.amd.com -A -o name 2>/dev/null)" ]; then
  echo "ℹ️  A DeviceConfig already exists in the cluster — skipping AMD GPU Operator config"
else
  echo "📦 No DeviceConfig found — applying AMD GPU Operator config in namespace ${AMD_GPU_NS}..."
  # FIXME: Use amd-gpu-operator-config/v1.4.1
  helm template amd-gpu-operator-config ${SOURCES_DIR}/amd-gpu-operator-config \
    --namespace "${AMD_GPU_NS}" \
    --set namespace="${AMD_GPU_NS}" \
    | ssa_apply -n "${AMD_GPU_NS}"
  echo "✅ AMD GPU Operator config applied"
fi
echo ""

# ============================================================================
# AMD GPU NODE LABEL (NodeFeatureRule fallback)
# ============================================================================
step "AMD GPU node labelling (NodeFeatureRule fallback)"
# The AMD GPU operator's device-plugin / metrics-exporter / node-labeller
# DaemonSets select on feature.node.kubernetes.io/amd-gpu=true. That label is
# produced by an NFD rule shipped inside the operator's own
# NodeFeatureDiscovery instance — but if another NodeFeatureDiscovery instance
# (e.g. a generic "nfd-instance") owns the shared "nfd-worker" DaemonSet, the
# operator's rule is shadowed and never runs. AMD GPU nodes then stay
# unlabelled, the DaemonSets sit at DESIRED=0, and amd.com/gpu capacity is 0 —
# GPU workloads remain Pending with "Insufficient amd.com/gpu".
#
# Guard against that: if AMD GPU hardware (PCI vendor 1002) is present but no
# node carries the amd-gpu label, apply a standalone NodeFeatureRule. It is
# processed by nfd-master directly (independent of which worker config is
# active), so it labels the nodes regardless of the instance collision.
if kubectl get crd nodefeaturerules.nfd.k8s-sigs.io >/dev/null 2>&1; then
  AMD_HW_NODES=$(kubectl get nodes -l feature.node.kubernetes.io/pci-1002.present=true -o name 2>/dev/null | wc -l | tr -d ' ')
  AMD_LABELLED_NODES=$(kubectl get nodes -l feature.node.kubernetes.io/amd-gpu=true -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "${AMD_HW_NODES}" != "0" ] && [ "${AMD_LABELLED_NODES}" = "0" ]; then
    echo "⚠️  AMD GPU hardware detected but no node has feature.node.kubernetes.io/amd-gpu=true"
    echo "📦 Applying NodeFeatureRule to label AMD GPU nodes..."
    NFR_FILE="${EXTRA_DIR}/amd-gpu-nodefeaturerule.yaml"
    # WORKAROUND: same as scc.yaml — the manifest currently only lives on the
    # test-aiwb branch; fetch it if the cloned branch does not include it.
    if [ ! -f "${NFR_FILE}" ]; then
      echo "ℹ️  amd-gpu-nodefeaturerule.yaml not in cloned branch '${CLUSTER_FORGE_BRANCH}'; fetching from test-aiwb..."
      mkdir -p "$(dirname "${NFR_FILE}")"
      retry curl -fsSL \
        https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/extra/amd-gpu-nodefeaturerule.yaml \
        -o "${NFR_FILE}"
    fi
    retry kubectl apply --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f "${NFR_FILE}"
    echo "⏳ Waiting for nodes to receive the amd-gpu label..."
    for i in $(seq 1 12); do
      if [ "$(kubectl get nodes -l feature.node.kubernetes.io/amd-gpu=true -o name 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
        echo "✅ AMD GPU nodes labelled"
        break
      fi
      echo "  attempt ${i}/12 - not yet labelled, retrying..."
      sleep 5
    done
  else
    echo "ℹ️  AMD GPU node labelling OK (hw nodes: ${AMD_HW_NODES}, labelled: ${AMD_LABELLED_NODES}) — skipping NodeFeatureRule"
  fi
fi
echo ""

# ============================================================================
# AIM ENGINE (Controller + CRDs)
# ============================================================================
step "AIM Engine (controller + CRDs)"
# Required by AIWB for AIMService resources and model catalog

# Stage 1: Install CRDs
echo "📦 Installing AIM Engine CRDs..."
kubectl create namespace aim-system --dry-run=client -o yaml | kubectl apply -f -
#retry kubectl apply --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f ${SOURCES_DIR}/aim-engine-crds/0.2.2/crds.yaml --namespace aim-system --recursive
retry helm template aim-engine-crds oci://registry-1.docker.io/amdenterpriseai/aim-engine-crds-chart --version 0.2.5 --namespace aim-system | ssa_apply


# Stage 2: Install AIM Engine operator
echo "📦 Installing AIM Engine operator..."
# Routing disabled on OpenShift: enabling HTTPRoute routing causes Istio
# (pilot-discovery) to fight over the routes, leaving AIMServices stuck in Starting.
# The Kyverno "generate-routes-from-httproutes" policy handles exposure via OpenShift Routes.
helm template aim-engine oci://registry-1.docker.io/amdenterpriseai/aim-engine-chart --version 0.2.5 \
  --namespace aim-system \
  --set clusterRuntimeConfig.enable=true \
  --set clusterRuntimeConfig.spec.routing.enabled=false \
  | ssa_apply

# Stage 3: Install AIMClusterModelSource for model auto-discovery
echo "📦 Installing AIM Cluster Model Source (v0.11.0)..."
helm template aim-engine ${SOURCES_DIR}/aim-cluster-model-source/ \
  --namespace kaiwo-system > ./aim-cluster-model-source-deploy-manually.yaml
echo "WARNING: Check local file ./aim-cluster-model-source-deploy-manually.yaml for AIMClusterModelSource deployment"

echo "✅ AIM Engine installed"
echo ""

# ============================================================================
# AIWB INFRASTRUCTURE (Database and Secrets)
# ============================================================================
step "AIWB infrastructure (namespaces + secrets)"

echo "📦 Installing AIWB infrastructure..."
kubectl create namespace aiwb --dry-run=client -o yaml | kubectl apply -f -

# Create namespaces needed for secrets which don't exist yet
NAMESPACES=(
  airm
  demo
  keycloak
  metallb-system
  aim-system
  envoy-gateway-system
  workbench
  kaiwo-system
  minio-tenant-default
  cluster-auth
)

for ns in "${NAMESPACES[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Install AIWB secrets from local file
echo "  📦 Installing AIWB secrets..."
# Apply AIWB standalone secrets (always required, regardless of pluggable mode)
kubectl apply -f "${MANUAL_HELM_DIR}/secrets/secrets-aiwb.yaml"

# CNPG-related secrets: only needed when in-cluster Postgres (CNPG) is installed.
# Driven by AIWB_DB_USER/PASSWORD and KEYCLOAK_DB_USER/PASSWORD (plus the
# *_CNPG_SUPERUSER_* vars) so the username and password the CNPG cluster
# bootstraps match what AIWB / Keycloak read at startup. In PLUGGABLE_DB=true
# mode the env-based block below creates the *-db-user secrets pointing to the
# external Postgres host instead.
if [[ "${PLUGGABLE_DB}" != true ]]; then
  echo "  📦 Creating CNPG credential secrets..."
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
fi

# Object-storage credential Secret: AIWB / workbench pods read S3 credentials
# from `minio-credentials` (keys minio-access-key / minio-secret-key). These
# MUST match the SeaweedFS filer ApiUser identity, which is created from the same
# MINIO_API_* env vars in the SEAWEEDFS section below. In PLUGGABLE_S3=true mode
# the same Secret points AIWB at the external S3 endpoint instead.
if [[ "${PLUGGABLE_S3}" != true ]]; then
  echo "  📦 Creating object-storage credential secrets..."
  for ns in aiwb workbench; do
    kubectl create secret generic minio-credentials -n "${ns}" \
      --from-literal=minio-access-key="${MINIO_API_ACCESS_KEY}" \
      --from-literal=minio-secret-key="${MINIO_API_SECRET_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
fi

# Apply AIWB standalone mode specific secrets
kubectl apply -f "${MANUAL_HELM_DIR}/secrets/secrets-aiwb-standalone.yaml"
echo "  ✅ Secrets applied"

# Pluggable database: create credentials secrets that AIWB and Keycloak read
# at startup. The chart templates reference these via .Values.postgresql.userSecretName.
if [[ "${PLUGGABLE_DB}" == true ]]; then
  echo "  📦 Creating pluggable database credentials secrets..."
  kubectl create secret generic "${AIWB_DB_SECRET_NAME}" -n aiwb \
    --from-literal=username="${AIWB_DB_USER}" \
    --from-literal=password="${AIWB_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic "${KEYCLOAK_DB_SECRET_NAME}" -n keycloak \
    --from-literal=username="${KEYCLOAK_DB_USER}" \
    --from-literal=password="${KEYCLOAK_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  ✅ Pluggable database credentials secrets created"
fi

# Pluggable S3: create minio-credentials secrets that AIWB and workbench pods
# read at startup, populated from MINIO_API_ACCESS_KEY / MINIO_API_SECRET_KEY
# env vars so AIWB authenticates against the external MinIO.
if [[ "${PLUGGABLE_S3}" == true ]]; then
  echo "  📦 Creating pluggable S3 credentials secrets..."
  for ns in aiwb workbench; do
    kubectl create secret generic minio-credentials -n "${ns}" \
      --from-literal=minio-access-key="${MINIO_API_ACCESS_KEY}" \
      --from-literal=minio-secret-key="${MINIO_API_SECRET_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  echo "  ✅ Pluggable S3 credentials secrets created"
fi

# ============================================================================
# CLUSTER-AUTH SHIM (standalone mode only)
# ============================================================================
step "cluster-auth shim (standalone)"
# cluster-auth normally requires OpenBao for API key group persistence.
# This in-memory shim implements the cluster-auth REST API so that aiwb-api
# can create API key groups for model deployments without OpenBao.
# State is lost on pod restart; suitable for standalone/dev installs only.
echo "📦 Installing cluster-auth shim..."

kubectl create configmap cluster-auth-shim \
  -n cluster-auth \
  --from-file=shim.py="${MANUAL_HELM_DIR}/scripts/cluster-auth-shim.py" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-auth
  template:
    metadata:
      labels:
        app: cluster-auth
    spec:
      containers:
      - name: shim
        image: python:3.11-slim
        command: ["python3", "/shim/shim.py"]
        ports:
        - containerPort: 8081
        volumeMounts:
        - name: shim
          mountPath: /shim
      volumes:
      - name: shim
        configMap:
          name: cluster-auth-shim
---
apiVersion: v1
kind: Service
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  selector:
    app: cluster-auth
  ports:
  - name: rest-api
    port: 8081
    targetPort: 8081
  type: ClusterIP
EOF

# Admin token secret consumed by aiwb-api as CLUSTER_AUTH_ADMIN_TOKEN
kubectl create secret generic cluster-auth-admin-token \
  -n aiwb \
  --from-literal=value=standalone-shim-token \
  --dry-run=client -o yaml | kubectl apply -f -

echo "⏳ Waiting for cluster-auth shim to be ready..."
kwait --for=condition=available --timeout=60s deployment/cluster-auth -n cluster-auth
echo "✅ cluster-auth shim is ready"
echo ""

# ============================================================================
# AIWB DATABASE CLUSTER
# ============================================================================
step "AIWB database cluster (CNPG)"
if [[ "${PLUGGABLE_DB}" != true ]]; then
  # Install AIWB PostgreSQL cluster
  echo " 📦 Installing AIWB database cluster (${CNPG_INSTANCES} instance(s))..."

  retry helm template aiwb-infra-cnpg \
    oci://registry-1.docker.io/amdenterpriseai/aiwb-cnpg-chart --version 2.0.0 \
    --set instances=${CNPG_INSTANCES} \
    --set username=${AIWB_DB_USER} \
    --set storage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
    --set walStorage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
    --namespace aiwb | ssa_apply

  echo "⏳ Waiting for AIWB database cluster to be ready..."
  sleep 2
  # Use the fully-qualified resource name: on OpenShift several CRDs register the
  # short name "cluster" (IBM ISF, NooBaa, GPFS, CNPG), so `kubectl get cluster`
  # resolves to the wrong group and never sees the CNPG cluster, hanging forever.
  until kubectl get clusters.postgresql.cnpg.io -n aiwb -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
    echo "  Still waiting for AIWB PostgreSQL cluster..."
    sleep 5
  done
  echo "✅ AIWB database is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for AIWB database."
fi

# ============================================================================
# KEYCLOAK (Identity and Access Management) - Start Early
# ============================================================================
step "Keycloak (identity & access management)"
# Start Keycloak installation now so it runs in parallel with MinIO
# We'll wait for it to be ready later, just before AIWB needs it
echo "📦 Starting Keycloak installation (will complete in background)..."

KEYCLOAK_PLUGGABLE_DB_ARGS=""
if [[ ${PLUGGABLE_DB} == true ]]; then
  echo "  📦 Installing Keycloak with pluggable database (host: ${POSTGRES_HOST}:${POSTGRES_PORT}, database: ${KEYCLOAK_DB_NAME})"
  KEYCLOAK_CNPG_ENABLED=false
  KEYCLOAK_PLUGGABLE_DB_ARGS="--set postgresql.host=${POSTGRES_HOST} --set postgresql.port=${POSTGRES_PORT} --set postgresql.database=${KEYCLOAK_DB_NAME} --set postgresql.userSecretName=${KEYCLOAK_DB_SECRET_NAME}"
else
  echo "  📦 Installing Keycloak with PostgreSQL cluster (${CNPG_INSTANCES} instance(s))..."
  KEYCLOAK_CNPG_ENABLED=true
fi

helm template keycloak ${SOURCES_DIR}/keycloak-old \
  --set externalSecrets.enabled=false \
  --set cnpg.enabled=${KEYCLOAK_CNPG_ENABLED} \
  --set cnpg.instances=${CNPG_INSTANCES} \
  --set cnpg.storage.storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
  --set domain="$DOMAIN" \
  --set hostname="${KC_HOSTNAME}" \
  --set postgresql.username=${KEYCLOAK_DB_USER} \
  --set 'extraEnvVars[0].name=JAVA_OPTS_APPEND' \
  --set 'extraEnvVars[0].value=-XX:MaxRAMPercentage=65.0 -XX:InitialRAMPercentage=50.0 -XX:MaxMetaspaceSize=512m -XX:+ExitOnOutOfMemoryError -Djava.awt.headless=true' \
  ${KEYCLOAK_PLUGGABLE_DB_ARGS} \
  --namespace keycloak | ssa_apply

echo "  ✅ Keycloak installation triggered (PostgreSQL + deployment starting)"
echo ""

# ============================================================================
# SEAWEEDFS (Object Storage)
# ============================================================================
step "SeaweedFS (object storage)"
# As of cluster-forge v2.x the in-cluster object store is SeaweedFS (not MinIO).
# AIWB still talks S3 to it via the "minio-credentials" Secret and the endpoint
# http://filer-s3.seaweedfs-instance.svc.cluster.local:80 (AIWB chart default).
#
# CREDENTIALS: upstream seaweedfs-config sources its S3 identities + admin
# password from OpenBao via ExternalSecrets (with a random API secret key). This
# standalone installer instead keeps its self-contained, env-driven secret model:
# we create the two Secrets the chart expects (seaweedfs-s3-config, and
# seaweedfs-admin-secret) directly from the MINIO_* env vars and strip the chart's
# ExternalSecrets, so the filer's ApiUser keys match the "minio-credentials"
# Secret that AIWB / workbench pods use.
if [[ "${PLUGGABLE_S3}" != true ]]; then
  echo "📦 Installing SeaweedFS (S3-compatible object storage)..."
  kubectl create namespace seaweedfs-operator --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace seaweedfs-instance --dry-run=client -o yaml | kubectl apply -f -

  # The Seaweed CRD must exist before the operator reconciles the Seaweed CR.
  echo "  📦 Installing SeaweedFS CRD..."
  retry kubectl apply --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" \
    -f ${SOURCES_DIR}/seaweedfs-crds/0.1.13/seaweed.seaweedfs.com_seaweeds.yaml
  kwait --for=condition=established --timeout=60s crd/seaweeds.seaweed.seaweedfs.com

  # Install the operator (webhook disabled — avoids a cert-manager dependency here).
  echo "  📦 Installing SeaweedFS operator..."
  helm template seaweedfs-operator ${SOURCES_DIR}/seaweedfs-operator/0.1.13 \
    --namespace seaweedfs-operator \
    --set domain="${DOMAIN}" \
    --set webhook.enabled=false \
    | ssa_apply -n seaweedfs-operator
  echo "⏳ Waiting for SeaweedFS operator to be ready..."
  kwait --for=condition=available --timeout=180s deployment/seaweedfs-operator -n seaweedfs-operator

  # Create (from env) the Secrets that seaweedfs-config normally pulls from OpenBao.
  #   seaweedfs-s3-config (s3.json): identities the filer S3 accepts. The ApiUser
  #     keys MUST equal the minio-credentials Secret AIWB / workbench read.
  #   seaweedfs-admin-secret (admin-password): SeaweedFS admin UI password.
  echo "  📦 Creating SeaweedFS S3 config + admin secrets (from env)..."
  # SeaweedFS's s3.json rejects duplicate accessKeys across identities (unlike
  # MinIO). The Console + ApiUser keys default to the same "placeholder" value, so
  # only emit the Console identity when its accessKey actually differs from
  # ApiUser's — otherwise a single ApiUser identity is written. ApiUser is the one
  # that must match the minio-credentials Secret AIWB / workbench pods read.
  SEAWEEDFS_IDENTITIES=$(cat <<JSON
    {
      "name": "ApiUser",
      "actions": ["Admin"],
      "credentials": [{ "accessKey": "${MINIO_API_ACCESS_KEY}", "secretKey": "${MINIO_API_SECRET_KEY}" }]
    }
JSON
)
  if [[ "${MINIO_CONSOLE_ACCESS_KEY}" != "${MINIO_API_ACCESS_KEY}" ]]; then
    SEAWEEDFS_IDENTITIES=$(cat <<JSON
    {
      "name": "Console",
      "actions": ["Admin"],
      "credentials": [{ "accessKey": "${MINIO_CONSOLE_ACCESS_KEY}", "secretKey": "${MINIO_CONSOLE_SECRET_KEY}" }]
    },
${SEAWEEDFS_IDENTITIES}
JSON
)
  fi
  SEAWEEDFS_S3_JSON=$(cat <<JSON
{
  "identities": [
${SEAWEEDFS_IDENTITIES}
  ]
}
JSON
)
  kubectl create secret generic seaweedfs-s3-config -n seaweedfs-instance \
    --from-literal=s3.json="${SEAWEEDFS_S3_JSON}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic seaweedfs-admin-secret -n seaweedfs-instance \
    --from-literal=admin-password="${MINIO_CONSOLE_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Install the instance config (Seaweed CR, filer-s3 Service, admin, bucket init
  # job, HTTPRoutes). Strip the chart's OpenBao ExternalSecrets — we created those
  # Secrets above, so nothing overwrites them with vault-random values.
  echo "  📦 Installing SeaweedFS instance (buckets: default-bucket, models, datasets)..."
  # The init job (cluster-tool image) runs `aws configure set`, which writes to
  # $HOME/.aws. Under OpenShift's arbitrary high UID, HOME defaults to "/" (no
  # /etc/passwd entry) and is not writable, so the AWS CLI dies with
  # "Permission denied: '/.aws'". The chart's Job template exposes no env hook, so
  # inject HOME=/tmp into just that container post-render (anchored on its unique
  # inline command line, independent of the image tag).
  helm template seaweedfs-config ${SOURCES_DIR}/seaweedfs-config \
    --namespace seaweedfs-instance \
    --set domain="${DOMAIN}" \
    --set seaweed.storageClassName="${DEFAULT_STORAGE_CLASS_NAME}" \
    --set 'initJob.buckets[0].name=default-bucket' \
    --set 'initJob.buckets[1].name=models' \
    --set 'initJob.buckets[2].name=datasets' \
    | strip_kind ExternalSecret \
    | sed '/^          command: \["\/bin\/bash", "-c"\]/i\          env:\n            - name: HOME\n              value: "/tmp"' \
    | ssa_apply -n seaweedfs-instance

  # SANITY CHECK: bound the filer-s3 endpoint wait so a broken SeaweedFS cluster
  # fails loudly instead of hanging. filer-s3 only gets endpoints once the filer
  # pod is Ready; if the operator never creates the master/volume/filer pods
  # (e.g. missing seaweeds/finalizers RBAC) or the filer crash-loops (e.g. bad
  # s3.json), dump the cluster/pod/sts state + filer logs and bail.
  echo "⏳ Waiting for SeaweedFS filer S3 endpoint to be ready..."
  sleep 5
  SEAWEEDFS_S3_TIMEOUT="${SEAWEEDFS_S3_TIMEOUT:-300}"
  sw_s3_elapsed=0
  until kubectl get endpoints filer-s3 -n seaweedfs-instance -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
    if [ "${sw_s3_elapsed}" -ge "${SEAWEEDFS_S3_TIMEOUT}" ]; then
      echo "❌ SeaweedFS filer-s3 has no endpoints after ${SEAWEEDFS_S3_TIMEOUT}s. Current state:"
      kubectl get seaweed,sts,pods -n seaweedfs-instance 2>&1 || true
      echo "--- seaweedfs operator log (tail) ---"
      kubectl logs deploy/seaweedfs-operator -n seaweedfs-operator --tail=20 2>&1 | tail -20 || true
      echo "--- filer log (tail) ---"
      kubectl logs seaweed-filer-0 -n seaweedfs-instance --tail=25 2>&1 | tail -25 || true
      echo "💡 Common causes: operator missing seaweeds/finalizers RBAC (no pods created)"
      echo "   or filer crash on a bad seaweedfs-s3-config s3.json (e.g. duplicate accessKey)."
      exit 1
    fi
    echo "  Still waiting for filer-s3 endpoints... (${sw_s3_elapsed}s/${SEAWEEDFS_S3_TIMEOUT}s)"
    sleep 5
    sw_s3_elapsed=$((sw_s3_elapsed + 5))
  done

  # SANITY CHECK: the bucket init job must actually complete — the buckets it
  # creates (default-bucket, models, datasets) are required by AIWB. On failure,
  # surface the latest init-job pod log (where the real error is) and bail
  # instead of continuing with missing buckets.
  echo "⏳ Waiting for SeaweedFS bucket init job to complete..."
  if ! kwait --for=condition=complete --timeout=300s job/seaweedfs-init-job -n seaweedfs-instance; then
    echo "❌ SeaweedFS bucket init job did not complete. Diagnostics:"
    kubectl get job seaweedfs-init-job -n seaweedfs-instance -o wide 2>&1 || true
    kubectl get pods -n seaweedfs-instance -l job-name=seaweedfs-init-job 2>&1 || true
    sw_init_pod=$(kubectl get pods -n seaweedfs-instance -l job-name=seaweedfs-init-job \
      --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
    if [ -n "${sw_init_pod}" ]; then
      echo "--- log: ${sw_init_pod} ---"
      kubectl logs "${sw_init_pod}" -n seaweedfs-instance --tail=30 2>&1 | tail -30 || true
    fi
    echo "💡 If the log shows \"Permission denied: '/.aws'\", the init container needs a"
    echo "   writable HOME (this script injects HOME=/tmp; check that patch applied)."
    exit 1
  fi
  echo "✅ SeaweedFS is ready"
  echo ""
else
  echo "PLUGGABLE_S3=true => Skipping in-cluster MinIO Operator, Tenant and configuration."
  echo ""

  # Redirect Service: forwards http://minio.minio-tenant-default.svc.cluster.local:80
  # to ${MINIO_HOST_IP}:${MINIO_PORT} so consumers that hardcode the in-cluster
  # MinIO URL (e.g. aim-performance via BUCKET_STORAGE_HOST) reach the external
  # storage transparently. AIWB itself talks to the external endpoint directly
  # via --set minio.url below and does not depend on this redirect.
  # See docs/manual_helm_install/EXTERNAL_FIXES.md "aim-performance hardcoded
  # BUCKET_STORAGE_HOST" for why this workaround is currently needed.
  echo "  📦 Creating in-cluster redirect Service for external MinIO..."
  echo "     target: ${MINIO_HOST_IP}:${MINIO_PORT}"
  # Remove any pre-existing minio Service / Endpoints first. If a previous
  # install ran in PLUGGABLE_S3=false mode, the MinIO Operator created a
  # selector-backed Service named "minio" — applying a selectorless Service
  # on top of it produces server-side-apply conflicts. The delete is a no-op
  # on fresh clusters thanks to --ignore-not-found.
  kubectl delete service minio   -n minio-tenant-default --ignore-not-found
  kubectl delete endpoints minio -n minio-tenant-default --ignore-not-found
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-tenant-default
spec:
  ports:
  - name: http-minio
    port: 80
    targetPort: ${MINIO_PORT}
    protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: minio
  namespace: minio-tenant-default
subsets:
- addresses:
  - ip: ${MINIO_HOST_IP}
  ports:
  - name: http-minio
    port: ${MINIO_PORT}
    protocol: TCP
EOF
  echo "  ✅ Redirect Service ready"
  echo ""
  echo "Run scripts/s3.sh after this script completes for post-install verification."
  echo ""
fi

# ============================================================================
# WAIT FOR KEYCLOAK - Ready Check
# ============================================================================
step "Wait for Keycloak readiness"
# Keycloak was started earlier (in parallel with MinIO)
# Now wait for it to be ready before installing AIWB
if [[ "${PLUGGABLE_DB}" != true ]]; then
  echo "⏳ Waiting for Keycloak database cluster to be ready..."
  sleep 5
  # SANITY CHECK: bound the wait so a broken CNPG cluster fails loudly instead of
  # hanging forever. The classic failure here is the primary "initdb" pod stuck
  # Pending because its PVC (keycloak-cnpg-1) is missing / being deleted — usually
  # leftover PVCs from a previous keycloak-cnpg with stale ownerReferences. When we
  # time out, dump the cluster/pod/pvc state and the initdb pod events so the cause
  # is obvious, then bail with remediation guidance.
  KC_DB_TIMEOUT="${KC_DB_TIMEOUT:-600}"
  kc_db_elapsed=0
  # Fully-qualified name to avoid the ambiguous "cluster" short name on OpenShift.
  until kubectl get clusters.postgresql.cnpg.io keycloak-cnpg -n keycloak -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
    if [ "${kc_db_elapsed}" -ge "${KC_DB_TIMEOUT}" ]; then
      echo "❌ Keycloak CNPG cluster not healthy after ${KC_DB_TIMEOUT}s. Current state:"
      kubectl get cluster.postgresql.cnpg.io keycloak-cnpg -n keycloak -o wide 2>&1 || true
      kubectl get pods,pvc,jobs -n keycloak 2>&1 || true
      # Surface the scheduling reason for any stuck initdb pod (missing PVC, etc.).
      for p in $(kubectl get pods -n keycloak -o name 2>/dev/null | grep initdb); do
        echo "--- events: ${p} ---"
        kubectl describe -n keycloak "${p}" 2>&1 | sed -n '/Events:/,$p' | tail -15
      done
      echo "💡 If the initdb pod is Pending on a missing 'keycloak-cnpg-1' PVC, clear the"
      echo "   stale cluster and let it re-provision cleanly:"
      echo "     kubectl delete cluster.postgresql.cnpg.io keycloak-cnpg -n keycloak"
      echo "     kubectl delete job -n keycloak -l cnpg.io/cluster=keycloak-cnpg --ignore-not-found"
      echo "   then re-run this script."
      exit 1
    fi
    echo "  Still waiting for PostgreSQL cluster... (${kc_db_elapsed}s/${KC_DB_TIMEOUT}s)"
    sleep 5
    kc_db_elapsed=$((kc_db_elapsed + 5))
  done
  echo "✅ Keycloak database is ready"

  # Patch Keycloak readiness probe to give it more time to start before the
  # probe kicks in — avoids restart loops on slow nodes.
  kubectl patch deployment keycloak -n keycloak --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":120},
    {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":10}
  ]' 2>/dev/null || true

  # Wait for Keycloak deployment to be ready (7 min to account for slow starts)
  echo "⏳ Waiting for Keycloak to be ready..."
  kubectl wait --for=condition=available --timeout=420s deployment/keycloak -n keycloak || { echo "⚠️  Keycloak deployment check timed out, exiting..."; exit 1; }
  echo "✅ Keycloak is ready"
  echo ""
else
  echo "PLUGGABLE_DB=true => Not waiting for Keycloak or its database to be ready since it's going to be patched later."
fi


# ============================================================================
# AIWB APPLICATION
# ============================================================================
step "AIWB application"
# When PLUGGABLE_S3=true, point AIWB directly at the external MinIO endpoint
# rather than relying on the redirect Service. Keeps aiwb-api one indirection
# closer to the truth.
AIWB_PLUGGABLE_S3_ARGS=""
if [[ "${PLUGGABLE_S3}" == true ]]; then
  AIWB_PLUGGABLE_S3_ARGS="--set minio.url=http://${MINIO_HOST}:${MINIO_PORT} --set minio.bucket=${MINIO_BUCKET}"
fi

AIWB_PLUGGABLE_DB_ARGS=""
if [[ "${PLUGGABLE_DB}" == true ]]; then
  AIWB_PLUGGABLE_DB_ARGS="--set postgresql.host=${POSTGRES_HOST} --set postgresql.port=${POSTGRES_PORT} --set postgresql.database=${AIWB_DB_NAME} --set postgresql.userSecretName=${AIWB_DB_SECRET_NAME}"
fi

echo "🚀 Installing AIWB application..."
helm template aiwb oci://registry-1.docker.io/amdenterpriseai/aiwb-chart --version 2.0.0 \
  --namespace aiwb \
  --set standAloneMode=true \
  --set appDomain="${DOMAIN}" \
  --set backend.clusterHost="${AIWB_UI_URL}" \
  --set keycloak.url="${KC_URL}" \
  --set frontend.env.NEXTAUTH_URL="${AIWB_UI_URL}" \
  --set frontend.env.KEYCLOAK_ISSUER="${KC_URL}/realms/airm" \
  --set postgresql.username=${AIWB_DB_USER} \
  --set kgateway.namespace=envoy-gateway-system \
  ${AIWB_PLUGGABLE_S3_ARGS} \
  ${AIWB_PLUGGABLE_DB_ARGS} \
  | ssa_apply

# Wait for AIWB to be ready
echo "⏳ Waiting for AIWB to be ready..."
# AIWB may have multiple deployments, wait for the main one
kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=aiwb -n aiwb 2>/dev/null || echo "⚠️  AIWB deployment check completed with warnings"
echo "✅ AIWB application is ready"
echo ""

# ============================================================================
# AI GATEWAY DISCOVERY
# ============================================================================
step "AI Gateway Discovery"
echo "📦 Installing AI Gateway Discovery..."
kubectl create namespace ai-gateway-system --dry-run=client -o yaml | kubectl apply -f -
retry helm template ai-gateway-discovery oci://registry-1.docker.io/amdenterpriseai/ai-gateway-discovery-chart --version 2.0.0 \
  --namespace ai-gateway-system \
  --set controller.gateway.routeHostname=ai.${DOMAIN} \
  --set controller.gateway.name=ai-gateway \
  | ssa_apply

kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=ai-gateway-discovery -n ai-gateway-system 2>/dev/null || echo "⚠️  AI Gateway Discovery deployment check completed with warnings"
echo "✅ AI Gateway Discovery is ready"
echo ""

# ============================================================================
# RABBIT MQ
# ============================================================================
step "Rabbit MQ"
echo "📦 Installing Rabbit MQ..."
kubectl create namespace rabbitmq-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ${SOURCES_DIR}/rabbitmq/v2.15.0 --server-side  --force-conflicts --namespace rabbitmq-system
#kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=rabbitmq-cluster-operator -n rabbitmq-system 2>/dev/null || echo "⚠️  AI Gateway Discovery deployment check completed with warnings"
echo "✅ Rabbit MQ is ready"
echo ""

# ============================================================================
# KUEUE
# ============================================================================
step "Kueue"
echo "📦 Installing Kueue..."
kubectl create namespace kueue-system --dry-run=client -o yaml | kubectl apply -f -

# Values translated from the ArgoCD valuesObject (namespace/path/syncWave are
# ArgoCD-only metadata and are handled here by --namespace and the chart path).
# Written to a temp file because controllerManagerConfigYaml is a multi-line
# block that does not map cleanly to --set.
KUEUE_VALUES="$(mktemp)"
cat > "${KUEUE_VALUES}" <<'EOF'
controllerManager:
  replicas: 1
managerConfig:
  controllerManagerConfigYaml: |-
    apiVersion: config.kueue.x-k8s.io/v1beta1
    kind: Configuration
    health:
      healthProbeBindAddress: :8081
    metrics:
      bindAddress: :8443
    # enableClusterQueueResources: true
    webhook:
      port: 9443
    leaderElection:
      leaderElect: true
      resourceName: c1f6bfd2.kueue.x-k8s.io
    controller:
      groupKindConcurrency:
        Job.batch: 5
        Pod: 5
        Workload.kueue.x-k8s.io: 5
        LocalQueue.kueue.x-k8s.io: 1
        Cohort.kueue.x-k8s.io: 1
        ClusterQueue.kueue.x-k8s.io: 1
        ResourceFlavor.kueue.x-k8s.io: 1
    clientConnection:
      qps: 50
      burst: 100
    managedJobsNamespaceSelector:
      matchLabels:
        kueue-managed: "true"
    integrations:
      frameworks:
      - "batch/job"
      - "kubeflow.org/mpijob"
      - "ray.io/rayjob"
      - "ray.io/raycluster"
      - "jobset.x-k8s.io/jobset"
      - "kubeflow.org/paddlejob"
      - "kubeflow.org/pytorchjob"
      - "kubeflow.org/tfjob"
      - "kubeflow.org/xgboostjob"
      - "kubeflow.org/jaxjob"
      - "workload.codeflare.dev/appwrapper"
      - "pod"
      - "deployment"
      - "statefulset"
mutatingWebhook:
  reinvocationPolicy: IfNeeded
EOF

helm template kueue ${SOURCES_DIR}/kueue/0.13.0 \
  --namespace kueue-system \
  -f "${KUEUE_VALUES}" \
  | ssa_apply
rm -f "${KUEUE_VALUES}"

kubectl apply -f ${SOURCES_DIR}/kueue-config --namespace kueue-system --server-side --force-conflicts --request-timeout="${KUBECTL_REQUEST_TIMEOUT}"

kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=kueue -n kueue-system 2>/dev/null || echo "⚠️  Kueue deployment check completed with warnings"
echo "✅ Kueue is ready"
echo ""

# ============================================================================
# KAIWO CRDS (Custom Resource Definitions for Kaiwo)
# ============================================================================
step "Kaiwo CRDs"
echo "📦 Installing Kaiwo CRD..."
#kubectl create namespace kaiwo --dry-run=client -o yaml | kubectl apply -f -
retry helm template kaiwo-crds oci://ghcr.io/silogen/kaiwo-crds-chart --version v0.2.1 \
  --namespace kaiwo-system \
  | ssa_apply

# ============================================================================
# KAIWO 
# ============================================================================
step "Kaiwo "
echo "📦 Installing Kaiwo..."

helm template kaiwo oci://ghcr.io/silogen/kaiwo-operator-chart --version v0.2.1 \
  --namespace kaiwo-system \
  | ssa_apply

# kaiwo-config ships an ExternalSecret pinned to the removed external-secrets.io/v1beta1
# API; this cluster's external-secrets operator only serves v1. Rewrite the version
# before applying (same fix as the otel-lgtm stack). Concatenate the dir's manifests
# with explicit "---" separators so ssa_apply (which reads a single stream) still sees
# each document, and reuse its retry + --force-conflicts behaviour.
for f in ${SOURCES_DIR}/kaiwo-config/*.yaml; do echo "---"; cat "$f"; done \
  | sed 's#external-secrets.io/v1beta1#external-secrets.io/v1#g' \
  | ssa_apply --namespace kaiwo-system

# ============================================================================
# OpenShift Routes — expose AIWB UI/API and Keycloak via the cluster router.
# On OpenShift we use native Routes instead of Gateway API HTTPRoutes, so apply
# them as the final step once all Services exist.
# ============================================================================
step "Apply OpenShift Routes (AIWB UI/API + Keycloak)"
ROUTES_FILE="${EXTRA_DIR}/routes.yaml"
echo "🌐 Applying OpenShift Routes..."
# WORKAROUND: routes.yaml currently only lives on the test-aiwb branch (same as
# scc.yaml). If it is missing from the clone, fetch it from test-aiwb so the
# apply works regardless of which branch was cloned. (Remove once merged.)
if [ ! -f "${ROUTES_FILE}" ]; then
  echo "ℹ️  routes.yaml not in cloned branch '${CLUSTER_FORGE_BRANCH}'; fetching from test-aiwb..."
  mkdir -p "$(dirname "${ROUTES_FILE}")"
  retry curl -fsSL \
    https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/extra/routes.yaml \
    -o "${ROUTES_FILE}"
fi
# Substitute the ${DOMAIN} placeholder in the Route host fields with the cluster's
# apps domain before applying (sed is used instead of envsubst for portability).
sed "s|\${DOMAIN}|${DOMAIN}|g" "${ROUTES_FILE}" | ssa_apply
echo "✅ OpenShift Routes applied (domain: ${DOMAIN})"
echo ""

echo "💡 Verification commands:"
echo "   kubectl get pods -n keycloak"
echo "   kubectl get pods -n aiwb"
echo "   kubectl get pods -n kaiwo-system"
echo "   kubectl get pods -n keda"
echo "   kubectl get pods -n otel-lgtm-stack"
# echo "   kubectl get pods -n kueue-system"
echo "   kubectl get pods -n cnpg-system"
echo "   kubectl get pods -n seaweedfs-instance"
echo "   kubectl get pods -n seaweedfs-operator"
# echo "   kubectl get pods -n rabbitmq-system"
echo "   kubectl get pods -n amd-gpu-operator"
echo "   kubectl get clusters.postgresql.cnpg.io --all-namespaces"
echo "   kubectl get routes -n aiwb"
echo "   kubectl get routes -n keycloak"
echo ""
if [ "$DOMAIN" = "localhost" ]; then
  GATEWAY_IP=$(kubectl get gateway https -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")
  echo "💡 Local Access via Gateway LoadBalancer:"
  echo "   Gateway IP: ${GATEWAY_IP}:8080"
  echo ""
  echo "   Access services using Host headers:"
  echo "   # AIWB UI"
  echo "   curl -H 'Host: aiwbui.localhost' http://${GATEWAY_IP}:8080"
  echo ""
  echo "   # AIWB API"
  echo "   curl -H 'Host: aiwbapi.localhost' http://${GATEWAY_IP}:8080/health"
  echo ""
  echo "   # Keycloak"
  echo "   curl -H 'Host: kc.localhost' http://${GATEWAY_IP}:8080/health"
  echo ""
  echo "   Add to /etc/hosts for browser access:"
  echo "   ${GATEWAY_IP} aiwbui.localhost aiwbapi.localhost kc.localhost"
  echo ""
  echo "💡 Alternative: Port Forward (if Gateway IP not accessible):"
  echo "   kubectl port-forward -n aiwb svc/aiwb-ui 8000:8000"
  echo "   kubectl port-forward -n aiwb svc/aiwb-api 8001:8080"
  echo "   kubectl port-forward -n keycloak svc/keycloak 8080:8080"
  echo "   kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000  # Grafana"
  echo "   kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090  # Prometheus"
else
  echo "💡 Access:"
  GATEWAY_IP=$(kubectl get gateway https -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "${DOMAIN}")
  echo "   Gateway IP: ${GATEWAY_IP}:8080"
  echo "   AIWB UI: https://aiwbui.${DOMAIN}"
  echo "   AIWB API: https://aiwbapi.${DOMAIN}"
  echo "   Keycloak: https://kc.${DOMAIN}"
  echo ""
  echo "   Ensure DNS points aiwbui.${DOMAIN}, aiwbapi.${DOMAIN}, and kc.${DOMAIN} to ${GATEWAY_IP}"
fi
echo ""
echo "💡 Keycloak Admin Credentials:"
echo "   Username: silogen-admin"
echo "   Password: placeholder"
echo "   Admin Console: http://${DOMAIN}:8080/admin"
echo ""
echo "💡 AIWB User Login:"
echo "   Username: devuser@${DOMAIN}"
echo "   Password: placeholder"
echo ""
echo "📊 Observability (Grafana, Prometheus, Loki, Tempo):"
echo "   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000"
echo "   Access Grafana at: http://localhost:3000"
echo "   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090"
echo "   Access Prometheus at: http://localhost:9090"
echo ""
echo "ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md"
echo ""

if [[ "$PLUGGABLE_DB" == true ]]; then
  echo ""
  echo "PLUGGABLE_DB=true => AIWB and Keycloak deployed against external PostgreSQL:"
  echo "  Host:     ${POSTGRES_HOST}:${POSTGRES_PORT}"
  echo "  AIWB DB:  ${AIWB_DB_NAME} (user: ${AIWB_DB_USER}, secret: ${AIWB_DB_SECRET_NAME})"
  echo "  Keycloak: ${KEYCLOAK_DB_NAME} (user: ${KEYCLOAK_DB_USER}, secret: ${KEYCLOAK_DB_SECRET_NAME})"
  echo "Ensure the databases and roles exist on your PostgreSQL server"
  echo "(see components/db.md for setup instructions)."
fi

# ============================================================================
# CLEANUP
# ============================================================================
# Reaching this point means the script completed successfully (set -e aborts on
# any earlier failure). Remove the cloned cluster-forge sources to free space.
# The :? guard ensures we never run rm -rf on an empty/unset path.
step "Cleanup (remove downloaded cluster-forge sources)"
echo "🧹 Cleaning up cluster-forge sources at ${CLUSTER_FORGE_DIR}..."
rm -rf "${CLUSTER_FORGE_DIR:?CLUSTER_FORGE_DIR is unset}"
echo "✅ Cleanup complete"

echo ""
echo "✅ Deploy complete"

# TODO: Missing apps???
# aiwb-infra-external-secrets


# kyverno-policies-storage-local-path DONE????
# cluster-auth-config NOT IN OPENSHIFT???

# envoy-ai-gateway-crds
# envoy-ai-gateway
# inference-extension-crds

  # aiwb-infra-external-secrets:
  #   repoURL: "{{ .Values.ociRegistry.dockerHub }}"
  #   repoVersion: "2.0.0"
  #   chart: "aiwb-external-secrets-chart"
  #   namespace: aiwb
  #   syncWave: -20
  #   valuesFile: values.yaml
  #   ignoreDifferences:
  #     - group: external-secrets.io
  #       kind: ExternalSecret
  #       jqPathExpressions:
  #         - ".spec.data[].remoteRef.conversionStrategy"
  #         - ".spec.data[].remoteRef.decodingStrategy"
  #         - ".spec.data[].remoteRef.metadataPolicy"

  # kaiwo-crds:
  #   repoURL: "{{ .Values.ociRegistry.ghcr }}"
  #   repoVersion: "v0.2.1"
  #   chart: "kaiwo-crds-chart"
  #   namespace: kaiwo
  # kaiwo:
  #   repoURL: "{{ .Values.ociRegistry.ghcr }}"
  #   repoVersion: "v0.2.1"
  #   chart: "kaiwo-operator-chart"
  #   namespace: kaiwo-system
  #   syncWave: -10
  # kaiwo-config:
  #   ignoreDifferences:
  #     - group: external-secrets.io
  #       jqPathExpressions:
  #         - ".spec.data[].remoteRef.conversionStrategy"
  #         - ".spec.data[].remoteRef.decodingStrategy"
  #         - ".spec.data[].remoteRef.metadataPolicy"
  #       kind: ExternalSecret
  #     - group: ""
  #       jsonPointers:
  #         - /spec/accessModes
  #       kind: "PersistentVolumeClaim"
  #   namespace: kaiwo-system
  #   path: kaiwo-config
  #   syncWave: 0
