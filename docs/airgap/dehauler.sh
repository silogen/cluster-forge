#!/usr/bin/env bash
# Sections 4.1-4.4: load, serve, configure RKE2, and apply the complete EAI
# haul in Cluster-Forge install order.
#
#   sudo ./dehauler.sh --confirm
#   sudo ./dehauler.sh --from 25 --confirm
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPT_DIR"

# Project layout: dehauler.sh is above haul/. Wrapper layout: dehauler.sh is
# beside eai-stack.tar.zst. Both work without environment variables.
if [[ -d "$SCRIPT_DIR/haul/eai-store" || -f "$SCRIPT_DIR/haul/eai-stack.tar.zst" ]]; then
  DEFAULT_HAUL_ROOT="$SCRIPT_DIR/haul"
else
  DEFAULT_HAUL_ROOT="$SCRIPT_DIR"
fi
HAUL_ROOT="${HAUL_ROOT:-$DEFAULT_HAUL_ROOT}"
EAI_STORE="${EAI_STORE:-$HAUL_ROOT/eai-store}"
TMPDIR="${TMPDIR:-$HAUL_ROOT/tmp}"
export TMPDIR
EXTRACT_DIR="${EXTRACT_DIR:-$HAUL_ROOT/extracted}"
LOCAL_REG="${LOCAL_REG:-127.0.0.1:5000}"
CF_DOMAIN="${CF_DOMAIN:-hauler1.silogen.ai}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
REGISTRY_WAIT_TIMEOUT="${REGISTRY_WAIT_TIMEOUT:-300}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"
METALLB_WAIT_TIMEOUT="${METALLB_WAIT_TIMEOUT:-180}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export KUBECONFIG
PATH="/usr/local/bin:/var/lib/rancher/rke2/bin:${PATH}"
export PATH
FROM_STEP=1
DRY_RUN=0
CONFIRM="${CONFIRM:-0}"

# Deployment shape, and the credentials the inline object steps carry. Names,
# defaults and skipWhen semantics are install.sh's, so the same environment
# drives either install path.
#
# false on both means the cluster brings its own PostgreSQL (CNPG) and object
# store (SeaweedFS), which is what the air-gapped path was built for. The
# placeholder credentials are install.sh's too: fine for a throwaway cluster,
# and to be set for anything else.
PLUGGABLE_DB="${PLUGGABLE_DB:-false}"
PLUGGABLE_S3="${PLUGGABLE_S3:-false}"

export DOMAIN="${DOMAIN:-$CF_DOMAIN}"
export MINIO_API_ACCESS_KEY="${MINIO_API_ACCESS_KEY:-placeholder}"
export MINIO_API_SECRET_KEY="${MINIO_API_SECRET_KEY:-placeholder}"
export MINIO_CONSOLE_ACCESS_KEY="${MINIO_CONSOLE_ACCESS_KEY:-placeholder}"
export MINIO_CONSOLE_SECRET_KEY="${MINIO_CONSOLE_SECRET_KEY:-placeholder}"
export MINIO_PORT="${MINIO_PORT:-9999}"
export MINIO_HOST_IP="${MINIO_HOST_IP:-192.168.127.254}"
export AIWB_DB_USER="${AIWB_DB_USER:-aiwb_user}"
export AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"
export KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloak}"
export KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"
export AIWB_CNPG_SUPERUSER_USER="${AIWB_CNPG_SUPERUSER_USER:-placeholder}"
export AIWB_CNPG_SUPERUSER_PASSWORD="${AIWB_CNPG_SUPERUSER_PASSWORD:-placeholder}"
export KEYCLOAK_CNPG_SUPERUSER_USER="${KEYCLOAK_CNPG_SUPERUSER_USER:-placeholder}"
export KEYCLOAK_CNPG_SUPERUSER_PASSWORD="${KEYCLOAK_CNPG_SUPERUSER_PASSWORD:-placeholder}"
export KEYCLOAK_INITIAL_ADMIN_PASSWORD="${KEYCLOAK_INITIAL_ADMIN_PASSWORD:-placeholder}"
export KEYCLOAK_INITIAL_DEVUSER_PASSWORD="${KEYCLOAK_INITIAL_DEVUSER_PASSWORD:-placeholder}"

# Derived the way install.sh derives them.
export AI_HOST="${AI_HOST:-ai.${DOMAIN}}"
export AIWB_UI_URL="${AIWB_UI_URL:-https://aiwbui.${DOMAIN}}"
export KC_URL="${KC_URL:-https://kc.${DOMAIN}}"
export MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
export MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
export AI_GATEWAY_MCP_SEED="${AI_GATEWAY_MCP_SEED:-cluster-forge-default-seed-override-in-production}"
# Where the AMD GPU operator runs. The metrics collector's scrape config
# hardcodes a namespace, and a job pointed at the wrong one finds no targets
# and reports nothing while the collector stays 1/1. dehauler.sh installs the
# operator into kube-amd-gpu, so that is the default here rather than
# install.sh's amd-gpu-operator.
export CF_AMD_GPU_NS="${CF_AMD_GPU_NS:-kube-amd-gpu}"
export POSTGRES_HOST="${POSTGRES_HOST:-host.docker.internal}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
export AIWB_DB_NAME="${AIWB_DB_NAME:-aiwb}"
# The StorageClass charts are pointed at. "default" is a real class created by
# step 4.4.0a, not a request for the cluster default.
export CF_STORAGE_CLASS="${CF_STORAGE_CLASS:-default}"

# Wildcard/domain TLS for the Gateway listeners. This is not the
# envoy-gateway webhook Secret: that one is minted by step 4.4.21a.
CLUSTER_TLS_NS="${CLUSTER_TLS_NS:-envoy-gateway-system}"
CLUSTER_TLS_NAME="${CLUSTER_TLS_NAME:-cluster-tls}"
CLUSTER_TLS_CERT="${CLUSTER_TLS_CERT:-}"
CLUSTER_TLS_KEY="${CLUSTER_TLS_KEY:-}"

usage() {
  cat <<'EOF'
Usage: sudo ./dehauler.sh [--from N] [--confirm] [--dry-run]

  Complete disconnected-side workflow:
    1. Use the existing store, or load eai-stack.tar.zst when absent.
    2. Start the Hauler registry with nohup and wait for /v2/.
    3. Write the RKE2 localhost HTTP mirror, restart RKE2 when changed,
       and wait for the node to become Ready.
    4. Apply hauled charts and files in Cluster-Forge order.

  Each step waits for that namespace's workloads to roll out before the next
  one, so webhook-backed charts (cert-manager, Kyverno) are serving when a
  later chart's CRs are validated.

  --from N    Skip steps before N (1-43). Lettered steps (4.4.13b and the
              rest) are gated on the integer step that follows them, so
              resuming never skips one of their prerequisites.
  --confirm   Pause after every step. Press Enter to continue, Ctrl-C to stop.
              Use this to wait for CNPG initdb, webhooks, or OpenBao before
              the next chart. Requires a TTY (do not nohup).
  --dry-run   Print steps only.

Environment:
  HAUL_ROOT     directory with archive/store (auto-detected from script path)
  EAI_STORE     Hauler store path (default $HAUL_ROOT/eai-store)
  TMPDIR        scratch dir on the large volume (default $HAUL_ROOT/tmp)
  LOCAL_REG     registry host:port (default 127.0.0.1:5000)
  CF_DOMAIN     cluster domain for charts that take --set domain (default hauler1.silogen.ai)
  WAIT_TIMEOUT  per-workload rollout timeout (default 300s)
  REGISTRY_WAIT_TIMEOUT seconds to wait for registry /v2/ (default 300)
  METALLB_IP_RANGE  L2 pool range; defaults to the first-node InternalIP /32
  METALLB_WAIT_TIMEOUT seconds to wait for MetalLB/Gateway addresses (default 180)
  KUBECONFIG    defaults to /etc/rancher/rke2/rke2.yaml
  CONFIRM       set to 1 for the same pause as --confirm
  PLUGGABLE_DB  true when PostgreSQL lives outside the cluster (default false)
  PLUGGABLE_S3  true when the object store lives outside it (default false)
  CLUSTER_TLS_CERT  PEM full chain for secret cluster-tls (optional; prompted if missing)
  CLUSTER_TLS_KEY   PEM private key for that secret (optional; prompted if missing)

  The object steps also read the credentials install.sh reads, under the same
  names and defaults: MINIO_API_ACCESS_KEY, KEYCLOAK_INITIAL_ADMIN_PASSWORD,
  AIWB_DB_USER and the rest. Every one defaults to a placeholder, which is
  fine for a throwaway cluster and nothing else.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --from)
      FROM_STEP="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --confirm)
      CONFIRM=1
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

find_hauler() {
  if command -v hauler >/dev/null 2>&1; then
    return 0
  fi
  local p
  for p in "$HAUL_ROOT/hauler" "$SCRIPT_DIR/haul/hauler" "$SCRIPT_DIR/hauler"; do
    if [[ -x "$p" ]]; then
      PATH="$(dirname "$(readlink -f "$p")"):${PATH}"
      export PATH
      return 0
    fi
  done
  return 1
}

# OCI registries often answer GET /v2/ with 401 (WWW-Authenticate). curl -f
# treats that as failure even though the server is up.
registry_is_up() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${LOCAL_REG}/v2/" 2>/dev/null || true)
  [[ "$code" == 200 || "$code" == 401 || "$code" == 403 ]]
}

registry_pid() {
  local pid=""
  if [[ -s "$HAUL_ROOT/hauler-registry.pid" ]]; then
    pid=$(<"$HAUL_ROOT/hauler-registry.pid")
  fi
  if [[ ! -d "/proc/${pid:-none}" ]]; then
    pid=$(pgrep -f "hauler store serve registry" | head -n 1 || true)
  fi
  [[ -n "$pid" && -d "/proc/$pid" ]] || return 1
  printf '%s' "$pid"
}

# `store serve registry` copies the store into the registry it serves, once, at
# startup. Re-packing the store afterwards therefore changes nothing that is
# being served, and the images added by that pack answer with NAME_UNKNOWN
# while `store info` lists them -- kubelet reports "not found" for an image the
# haul demonstrably contains. /proc/<pid> is created when the process starts,
# so its mtime against the store index says whether the pack came later.
registry_is_stale() {
  local pid store_at reg_at
  pid=$(registry_pid) || return 1
  [[ -f "$EAI_STORE/index.json" ]] || return 1
  store_at=$(stat -c %Y "$EAI_STORE/index.json" 2>/dev/null || echo 0)
  reg_at=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)
  (( store_at > reg_at ))
}

stop_registry() {
  local pid elapsed=0
  pid=$(registry_pid) || return 0
  kill "$pid" 2>/dev/null || true
  while (( elapsed < 30 )); do
    [[ -d "/proc/$pid" ]] || break
    sleep 1
    elapsed=$((elapsed + 1))
  done
  [[ -d "/proc/$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  rm -f "$HAUL_ROOT/hauler-registry.pid"
}

prepare_host() {
  [[ "$EUID" -eq 0 ]] || die "run this script with sudo"
  find_hauler || die "hauler is missing (expected on PATH or inside the haul)"
  command -v helm >/dev/null || die "helm is missing"
  command -v kubectl >/dev/null || die "kubectl is missing"
  command -v curl >/dev/null || die "curl is missing"
  command -v systemctl >/dev/null || die "systemctl is missing"
  [[ -r "$KUBECONFIG" ]] || die "cannot read KUBECONFIG=$KUBECONFIG"

  mkdir -p "$HAUL_ROOT" "$TMPDIR" "$EXTRACT_DIR"

  # The per-namespace kubeconfigs below are copies, so they keep the cluster CA
  # they were written with. Reinstalling RKE2 mints a new one, and every apply
  # then fails with "certificate signed by unknown authority" while the real
  # kubeconfig works. They cost nothing to rebuild, so start each run without
  # them rather than trying to tell a rebuild apart from a restart.
  rm -f "$TMPDIR"/kubeconfig-*

  echo "==> 4.1 preparing Hauler store: $EAI_STORE"
  if [[ ! -f "$EAI_STORE/index.json" ]]; then
    local archive="$HAUL_ROOT/eai-stack.tar.zst"
    [[ -f "$archive" ]] || die "store is absent and archive not found: $archive"
    mkdir -p "$EAI_STORE"
    hauler store load --filename "$archive" --store "$EAI_STORE"
  else
    echo "    using existing packed/loaded store"
  fi
  hauler store info --store "$EAI_STORE" >/dev/null

  echo "==> 4.2 ensuring registry is listening at http://${LOCAL_REG}"
  if registry_is_up && registry_is_stale; then
    echo "    the store was packed after the registry started - restarting it"
    stop_registry
  fi
  if ! registry_is_up; then
    nohup hauler store serve registry --store "$EAI_STORE" \
      >"$HAUL_ROOT/hauler-registry.log" 2>&1 &
    echo "$!" >"$HAUL_ROOT/hauler-registry.pid"
    echo "    waiting for the registry to listen"
  else
    echo "    registry already running"
  fi

  local elapsed=0
  until registry_is_up; do
    if (( elapsed >= REGISTRY_WAIT_TIMEOUT )); then
      tail -50 "$HAUL_ROOT/hauler-registry.log" >&2 2>/dev/null || true
      die "registry did not become ready within ${REGISTRY_WAIT_TIMEOUT}s"
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "    registry ready"

  echo "==> 4.3 configuring RKE2 HTTP mirror"
  local registry_file=/etc/rancher/rke2/registries.yaml
  local desired
  desired=$(cat <<'EOF'
mirrors:
  "127.0.0.1:5000":
    endpoint:
      - "http://127.0.0.1:5000"
EOF
)
  mkdir -p /etc/rancher/rke2
  if [[ ! -f "$registry_file" ]] || [[ "$(cat "$registry_file")" != "$desired" ]]; then
    if [[ -f "$registry_file" ]]; then
      cp -a "$registry_file" "${registry_file}.bak.$(date +%Y%m%d%H%M%S)"
      echo "    backed up existing registries.yaml"
    fi
    printf '%s\n' "$desired" >"$registry_file"
    systemctl restart rke2-server
    echo "    restarted rke2-server"
  else
    echo "    mirror already configured; restart not needed"
  fi

  elapsed=0
  until kubectl get nodes >/dev/null 2>&1; do
    if (( elapsed >= 180 )); then
      systemctl --no-pager --full status rke2-server >&2 || true
      die "Kubernetes API did not return after RKE2 restart"
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

should_run() {
  local n=$1
  [[ "$n" -ge "$FROM_STEP" ]]
}

# Pause after a step so you can wait for init jobs, webhooks, or CNPG
# clusters before the next apply. Reads from /dev/tty so sudo still works.
pause_between() {
  local ns=${1:-}
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$CONFIRM" != 1 ]] && return 0
  if [[ -n "$ns" ]] && kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "    pods in ${ns}:"
    kubectl -n "$ns" get pods 2>/dev/null || true
  fi
  echo
  echo "Press Enter to continue to the next step, or Ctrl-C to stop."
  read -r _ </dev/tty
}

rewrite_images() {
  # external-secrets.io/v1beta1 is no longer served by the 0.19.2 CRDs, and
  # several Cluster-Forge sources still declare it. values-openshift.yaml
  # applies the same substitution.
  #
  # Known registry hosts are rewritten first. Docker Hub org/name:tag (one
  # slash, no dot in the first segment) is next: amdenterpriseai/aiwb-api,
  # chrislusf/seaweedfs, kserve/kserve-controller. The last rule is a bare
  # `image: name:tag` (no slash), which the cluster-auth shim uses.
  # registries.yaml mirrors only 127.0.0.1:5000, so an unqualified reference
  # is not redirected anywhere -- it resolves to Docker Hub and the pull
  # leaves the air gap. A ref with no slash is a Docker Hub official image,
  # hence library/. Host rules above have already rewritten anything
  # registry-qualified, and those results contain a slash, so this cannot
  # double-rewrite them. The org/name rule skips 127.0.0.1 and any first
  # segment that contains a dot (already a registry host).
  sed -E \
    -e '/^Pulled:/d' \
    -e '/^Digest:/d' \
    -e 's#external-secrets\.io/v1beta1#external-secrets.io/v1#g' \
    -e "s#(registry-1\\.docker\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(docker\\.io/library/)#${LOCAL_REG}/library/#g" \
    -e "s#(docker\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(quay\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(ghcr\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(registry\\.k8s\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(gcr\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(nvcr\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(reg\\.kyverno\\.io/)#${LOCAL_REG}/#g" \
    -e "s#(oci\\.external-secrets\\.io/)#${LOCAL_REG}/#g" \
    -e "s#^([[:space:]]*-?[[:space:]]*image:[[:space:]]*)([\"']?)([a-z0-9][a-z0-9_-]*/[a-z0-9._-]+[a-z0-9._/-]*:[A-Za-z0-9._-]+)\\2[[:space:]]*\$#\\1\\2${LOCAL_REG}/\\3\\2#" \
    -e "s#^([[:space:]]*-?[[:space:]]*image:[[:space:]]*)([\"']?)([a-z0-9][a-z0-9._-]*:[A-Za-z0-9._-]+)\\2[[:space:]]*\$#\\1\\2${LOCAL_REG}/library/\\3\\2#"
}

# ${VAR} in a hauled object bundle, replaced from the environment. Unset or
# empty is fatal rather than expanded to nothing, because what uses this is
# domains and access keys: a Secret rendered with an empty one installs
# cleanly and is quietly wrong.
expand_env_refs() {
  python3 -c '
import os, re, sys
src = sys.stdin.read()
missing = sorted({m for m in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", src) if not os.environ.get(m)})
if missing:
    sys.exit("unset or empty: " + ", ".join(missing))
sys.stdout.write(re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: os.environ[m.group(1)], src))
'
}

# onlyKinds/excludeKinds, the way values-openshift.yaml uses them: one chart
# applied twice, split so the custom resources land after the webhook that
# validates them is serving. Kinds are read off the stream with a line matcher
# rather than a YAML parser, since PyYAML is not a given on a minimal host and
# helm output always writes kind: at the top level of a document.
filter_kinds() {
  local mode=$1
  shift
  python3 -c '
import re, sys
mode, kinds = sys.argv[1], set(sys.argv[2:])
for doc in re.split(r"(?m)^---\s*$", sys.stdin.read()):
    if not doc.strip():
        continue
    m = re.search(r"(?m)^kind:\s*(\S+)\s*$", doc)
    hit = bool(m) and m.group(1) in kinds
    if hit if mode == "only" else not hit:
        sys.stdout.write("---\n" + doc.strip("\n") + "\n")
' "$mode" "$@"
}

# Pipeline stage form of the above: a no-op unless CHART_KINDS is set to
# "only KIND..." or "exclude KIND..." just before an apply_chart call.
CHART_KINDS=""
maybe_filter_kinds() {
  if [[ -z "$CHART_KINDS" ]]; then
    cat
    return 0
  fi
  local -a spec
  read -r -a spec <<<"$CHART_KINDS"
  filter_kinds "${spec[@]}"
}

# StorageClasses that Cluster-Forge creates from handlers rather than charts.
# Existing classes are never touched: one of this name backed by something else
# means real storage was chosen here, and that choice outranks ours.
ensure_storageclass() {
  local name=$1
  local provisioner=${2:-rancher.io/local-path}
  local existing
  existing=$(kubectl get storageclass "$name" -o jsonpath='{.provisioner}' 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    if [[ "$existing" != "$provisioner" ]]; then
      echo "    WARNING: StorageClass ${name} uses ${existing}, not ${provisioner} - left alone" >&2
    else
      echo "    StorageClass ${name} already exists"
    fi
    return 0
  fi
  echo "    creating StorageClass ${name} (${provisioner})"
  kubectl apply --server-side --force-conflicts -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${name}
provisioner: ${provisioner}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
}

prepare_metallb() {
  # The native MetalLB manifest mounts this Secret in every speaker. Keep the
  # same value as Cluster-Forge's aiwb-infra objects so that the later apply is
  # a no-op instead of rotating a live memberlist key.
  kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n metallb-system create secret generic memberlist \
    --from-literal=secretkey=placeholder --dry-run=client -o yaml \
    | kubectl apply --server-side --force-conflicts -f - >/dev/null
}

configure_metallb() {
  local node node_ip ip_range elapsed=0

  # Envoy's external data plane is pinned to this same node. Cluster-Bloom
  # normally supplies the label; add it to the first Ready node when absent.
  node=$(kubectl get nodes -l cluster-bloom/first-node=true \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$node" ]]; then
    node=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {print $1; exit}')
    [[ -n "$node" ]] || die "cannot choose a Ready node for MetalLB"
    kubectl label node "$node" cluster-bloom/first-node=true --overwrite >/dev/null
    echo "    labelled ${node} cluster-bloom/first-node=true"
  fi

  node_ip=$(kubectl get node "$node" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  [[ -n "$node_ip" ]] || die "node ${node} has no InternalIP"
  ip_range="${METALLB_IP_RANGE:-${node_ip}/32}"

  echo "==> 4.4.9c configuring MetalLB L2 pool ${ip_range}"
  while (( elapsed < METALLB_WAIT_TIMEOUT )); do
    if [[ -n "$(kubectl get validatingwebhookconfiguration metallb-webhook-configuration \
      -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null)" ]]; then
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  (( elapsed < METALLB_WAIT_TIMEOUT )) \
    || die "MetalLB webhook did not become ready within ${METALLB_WAIT_TIMEOUT}s"

  kubectl apply --server-side --force-conflicts -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: cluster-bloom-ip-pool
  namespace: metallb-system
spec:
  addresses:
    - ${ip_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: cluster-bloom-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - cluster-bloom-ip-pool
EOF
  echo "    MetalLB will publish LoadBalancer services through ${ip_range}"
  pause_between metallb-system
}

wait_gateway_address() {
  local elapsed=0 svc=""
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  echo "    waiting for the https Gateway LoadBalancer address"
  while (( elapsed < METALLB_WAIT_TIMEOUT )); do
    svc=$(kubectl -n envoy-gateway-system get service \
      -l gateway.envoyproxy.io/owning-gateway-name=https \
      -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
      2>/dev/null || true)
    [[ -n "$svc" ]] && break
    sleep 3
    elapsed=$((elapsed + 3))
  done
  [[ -n "$svc" ]] \
    || die "https Gateway has no LoadBalancer address after ${METALLB_WAIT_TIMEOUT}s"
  echo "    https Gateway address: ${svc}"
}

ensure_ns() {
  local ns=$1
  [[ "$ns" == default ]] && return 0
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
}

# Wait for everything the step just created to be serving. Without this the
# next step's CRs can hit a webhook whose pod has no endpoints yet, e.g.
# "failed calling webhook webhook.cert-manager.io: no endpoints available".
wait_ready() {
  local ns=$1
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ -z "$ns" ]] && return 0
  kubectl get namespace "$ns" >/dev/null 2>&1 || return 0
  local kind obj
  for kind in deployment daemonset statefulset; do
    while read -r obj; do
      [[ -z "$obj" ]] && continue
      echo "    waiting for ${obj} in ${ns}"
      kubectl -n "$ns" rollout status "$obj" --timeout="$WAIT_TIMEOUT" || {
        echo "    WARNING: ${obj} in ${ns} not ready within ${WAIT_TIMEOUT}" >&2
        return 0
      }
    done < <(kubectl -n "$ns" get "$kind" -o name 2>/dev/null)
  done
}

# Some charts ship both a webhook and the custom resources that webhook
# validates (KServe's ClusterServingRuntimes, for one), so the first apply
# always loses the race. Retry, waiting for the workloads the failed apply
# just created to come up in between.
# Namespace defaulting, the way helm install does it.
#
# Charts leave metadata.namespace off namespaced objects and rely on the
# release namespace, so those objects need a default or they land in default.
# But `kubectl --namespace` is strict: it rejects any object that declares a
# different namespace, and Kueue binds extension-apiserver-authentication-reader
# in kube-system. A namespace set in the kubeconfig *context* only defaults the
# objects that omit one, so use a throwaway kubeconfig per namespace.
ns_kubeconfig() {
  local ns=$1
  local kc="$TMPDIR/kubeconfig-${ns}"
  if [[ ! -s "$kc" ]]; then
    kubectl config view --raw >"$kc"
    chmod 600 "$kc"
    kubectl --kubeconfig "$kc" config set-context --current --namespace="$ns" >/dev/null
  fi
  printf '%s' "$kc"
}

apply_stdin() {
  local ns=$1
  local attempt payload
  payload=$(cat)
  local -a kc=()
  [[ -n "$ns" ]] && kc=(--kubeconfig "$(ns_kubeconfig "$ns")")
  for attempt in 1 2 3; do
    if printf '%s\n' "$payload" | kubectl "${kc[@]}" apply --server-side --force-conflicts -f -; then
      return 0
    fi
    echo "    apply incomplete (attempt ${attempt}/3), waiting for ${ns} to settle" >&2
    wait_ready "$ns"
    sleep 10
  done
  echo "    apply still failing for ${ns}" >&2
  return 1
}

apply_chart() {
  local step=$1
  local release=$2
  local chart=$3
  local version=$4
  local ns=$5
  shift 5
  echo "==> ${step} helm ${release} (${chart}:${version}) ns=${ns}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  ensure_ns "$ns"
  # --no-hooks: helm template renders helm.sh/hook Pods and Jobs (the chart's
  # test pods among them), which kubectl would apply as real workloads.
  # maybe_filter_kinds consumes CHART_KINDS, set by the caller for a chart that
  # is applied in two parts.
  helm template "$release" "oci://${LOCAL_REG}/hauler/${chart}" --version "$version" --plain-http --include-crds --no-hooks --namespace "$ns" "$@" \
    | maybe_filter_kinds \
    | rewrite_images \
    | apply_stdin "$ns"
  CHART_KINDS=""
  wait_ready "$ns"
  pause_between "$ns"
}

store_file() {
  local name=$1
  mkdir -p "$EXTRACT_DIR"
  if ! hauler store extract "hauler/${name}:latest" --store "$EAI_STORE" -o "$EXTRACT_DIR" >&2; then
    hauler store extract "hauler/${name}" --store "$EAI_STORE" -o "$EXTRACT_DIR" >&2
  fi
  local f
  f=$(find "$EXTRACT_DIR" -name "$name" | head -n 1)
  if [[ -z "$f" ]]; then
    echo "could not find extracted file ${name} under ${EXTRACT_DIR}" >&2
    return 1
  fi
  printf '%s' "$f"
}

apply_file() {
  local step=$1
  local name=$2
  local ns=${3:-}
  echo "==> ${step} file ${name}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local f
  f=$(store_file "$name") || return 1
  rewrite_images < "$f" | apply_stdin "$ns"
  wait_ready "$ns"
  pause_between "$ns"
}

# The extraObjects steps, hauled as files by hauler.sh with their ${VAR}
# references left in. Same as apply_file but for the expansion, which cannot
# happen at pack time because the values are the deployment's, not the haul's.
apply_objects() {
  local step=$1
  local name=$2
  local ns=${3:-}
  echo "==> ${step} objects ${name}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local f
  f=$(store_file "$name") || return 1
  expand_env_refs < "$f" | maybe_filter_kinds | rewrite_images | apply_stdin "$ns"
  CHART_KINDS=""
  wait_ready "$ns"
  pause_between "$ns"
}

# Some steps in values-openshift.yaml are neither a chart nor a file: they are
# handlers install.sh runs against the live cluster. step_copy_objects is one,
# and re-publishing an object under a second name is the only part of it the
# air-gapped path needs.
#
# Everything the API server owns is stripped, so what is left applies as a new
# object. ownerReferences goes too: a copy that inherits the original's owner is
# garbage-collected the moment that owner is deleted, which would look like the
# copy having never been made.
copy_object() {
  local step=$1
  local kind=$2
  local from=$3
  local to=$4
  local ns=$5
  echo "==> ${step} copy ${kind}/${from} to ${kind}/${to} in ${ns}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  # The chart that creates the source applied moments ago, so tolerate the
  # object not being readable on the first try.
  local i
  for i in 1 2 3 4 5 6; do
    kubectl -n "$ns" get "$kind" "$from" >/dev/null 2>&1 && break
    [[ "$i" -eq 6 ]] && {
      echo "    cannot copy ${kind}/${from} in ${ns}: it does not exist" >&2
      echo "    the step that creates it has to run before this one" >&2
      return 1
    }
    sleep 5
  done

  kubectl -n "$ns" get "$kind" "$from" -o json \
    | python3 -c '
import json, sys
o = json.load(sys.stdin)
o.pop("status", None)
m = o["metadata"]
for k in ("resourceVersion", "uid", "creationTimestamp", "generation",
          "managedFields", "ownerReferences", "selfLink"):
    m.pop(k, None)
m.get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
m["name"] = sys.argv[1]
m["namespace"] = sys.argv[2]
json.dump(o, sys.stdout)
' "$to" "$ns" \
    | apply_stdin "$ns"
}

cluster_tls_ok() {
  kubectl -n "$CLUSTER_TLS_NS" get secret "$CLUSTER_TLS_NAME" >/dev/null 2>&1 || return 1
  local t
  t=$(kubectl -n "$CLUSTER_TLS_NS" get secret "$CLUSTER_TLS_NAME" -o jsonpath='{.type}' 2>/dev/null || true)
  [[ "$t" == kubernetes.io/tls ]] || return 1
  [[ -n "$(kubectl -n "$CLUSTER_TLS_NS" get secret "$CLUSTER_TLS_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)" ]] || return 1
  [[ -n "$(kubectl -n "$CLUSTER_TLS_NS" get secret "$CLUSTER_TLS_NAME" -o jsonpath='{.data.tls\.key}' 2>/dev/null)" ]] || return 1
}

print_cluster_tls_help() {
  cat <<EOF >&2

Secret ${CLUSTER_TLS_NAME} is missing (or is not a kubernetes.io/tls Secret
with tls.crt and tls.key) in namespace ${CLUSTER_TLS_NS}.

This is the wildcard/domain certificate the Gateway listeners terminate TLS
with. It is not the envoy-gateway webhook Secret: that one is named
envoy-gateway and step 4.4.21a mints it. Cluster-Forge copies this object
from the OpenShift router cert; that branch does not run here, so the secret
has to exist before the charts that reference it.

Create it from a full chain and private key (leaf-only fails for clients
that have not cached the Let's Encrypt intermediate):

  kubectl create namespace ${CLUSTER_TLS_NS} --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls ${CLUSTER_TLS_NAME} -n ${CLUSTER_TLS_NS} \\
    --cert=/path/to/fullchain.pem --key=/path/to/privkey.pem

Or set CLUSTER_TLS_CERT and CLUSTER_TLS_KEY to those paths and re-run this
script. Kaytoo setup_dns_cert stores the PEMs in 1Password; copy them onto
this host first.

EOF
}

create_cluster_tls() {
  local cert=$1
  local key=$2
  [[ -r "$cert" ]] || die "cannot read CLUSTER_TLS_CERT=$cert"
  [[ -r "$key" ]] || die "cannot read CLUSTER_TLS_KEY=$key"
  kubectl create secret tls "$CLUSTER_TLS_NAME" -n "$CLUSTER_TLS_NS" \
    --cert="$cert" --key="$key" \
    --dry-run=client -o yaml \
    | kubectl apply --server-side --force-conflicts -f -
  cluster_tls_ok || die "created ${CLUSTER_TLS_NS}/${CLUSTER_TLS_NAME} but it is not a usable TLS secret"
  echo "    created ${CLUSTER_TLS_NS}/${CLUSTER_TLS_NAME} from ${cert}"
}

# The Gateway controller creates Envoy Deployments from EnvoyProxy CRs. Those
# objects can keep docker.io even when global.images.envoyProxy.image was set
# on the helm chart, unless mergeType is set. Patch every EnvoyProxy in
# envoy-gateway-system to the hauled tag.
patch_envoy_proxy_images() {
  local ns=envoy-gateway-system
  local img="${LOCAL_REG}/envoyproxy/envoy:distroless-v1.38.1"
  echo "==> 4.4.23a EnvoyProxy data-plane image ${img}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local name
  while read -r name; do
    [[ -z "$name" ]] && continue
    echo "    patching EnvoyProxy/${name}"
    kubectl -n "$ns" patch envoyproxy "$name" --type merge -p "{\"spec\":{\"provider\":{\"type\":\"Kubernetes\",\"kubernetes\":{\"envoyDeployment\":{\"container\":{\"image\":\"${img}\"}}}}}}" \
      || echo "    WARNING: could not patch EnvoyProxy/${name}" >&2
  done < <(kubectl -n "$ns" get envoyproxy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  pause_between "$ns"
}

# The Gateway in envoy-gateway-config references this secret by name with no
# namespace, so it must already live in envoy-gateway-system. Prompt when a
# TTY is available; otherwise require CLUSTER_TLS_CERT/KEY or a pre-created
# secret.
ensure_cluster_tls() {
  echo "==> checking ${CLUSTER_TLS_NS}/${CLUSTER_TLS_NAME}"
  if cluster_tls_ok; then
    echo "    ${CLUSTER_TLS_NAME} is present"
    return 0
  fi
  print_cluster_tls_help
  if [[ -n "$CLUSTER_TLS_CERT" && -n "$CLUSTER_TLS_KEY" ]]; then
    create_cluster_tls "$CLUSTER_TLS_CERT" "$CLUSTER_TLS_KEY"
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    local cert="" key=""
    echo -n "Path to TLS certificate (full chain PEM), or empty to abort: " >&2
    read -r cert </dev/tty
    echo -n "Path to TLS private key PEM, or empty to abort: " >&2
    read -r key </dev/tty
    [[ -n "$cert" && -n "$key" ]] || die "${CLUSTER_TLS_NS}/${CLUSTER_TLS_NAME} is required; create it and re-run"
    create_cluster_tls "$cert" "$key"
    return 0
  fi
  die "${CLUSTER_TLS_NS}/${CLUSTER_TLS_NAME} is required; create it or set CLUSTER_TLS_CERT and CLUSTER_TLS_KEY"
}

# Render gateway-helm *with* hooks and keep every object Helm would run
# pre-install: the certgen ServiceAccount/Role/RoleBinding/ClusterRole/
# ClusterRoleBinding/Job, and the topology-injector MutatingWebhookConfiguration.
#
# The webhook has to be in that set even though its name says nothing about
# certgen. topologyInjector.enabled defaults to true, and certgen patches that
# webhook's caBundle after writing the Secrets; with the object absent the Job
# creates the Secrets and *then* fails, hitting backoffLimit. Selecting on the
# helm.sh/hook annotation rather than on the name is also exactly the
# complement of the --no-hooks apply that follows, so nothing is applied twice.
#
# Success is the Secret existing, not the Job reporting complete: the Job sets
# ttlSecondsAfterFinished: 30, so it can be garbage-collected before or during
# a wait on its condition.
apply_envoy_certgen() {
  local ns=envoy-gateway-system
  local webhook="envoy-gateway-topology-injector.${ns}"
  echo "==> 4.4.21a envoy-gateway certgen"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  ensure_ns "$ns"

  # Apply the hook objects other than the Job first. They are what certgen
  # needs in place to succeed, and server-side apply makes this a no-op when
  # they already exist.
  local hooks
  hooks=$(helm template envoy-gateway "oci://${LOCAL_REG}/hauler/gateway-helm" \
    --version v1.8.1 --plain-http --namespace "$ns" \
    | python3 -c '
import re, sys
for doc in re.split(r"(?m)^---\s*$", sys.stdin.read()):
    if doc.strip() and "helm.sh/hook" in doc:
        sys.stdout.write("---\n" + doc.strip("\n") + "\n")
')
  filter_kinds exclude Job <<<"$hooks" | rewrite_images | apply_stdin "$ns"

  # certgen writes the Secrets and then patches the webhook caBundle, so both
  # have to be there before this step is done. An empty caBundle means a
  # previous run created the Secrets and failed on the missing webhook.
  local ca=""
  ca=$(kubectl get mutatingwebhookconfiguration "$webhook" \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
  if kubectl -n "$ns" get secret envoy-gateway >/dev/null 2>&1 && [[ -n "$ca" ]]; then
    echo "    secret envoy-gateway and webhook caBundle are already in place"
    pause_between "$ns"
    return 0
  fi

  # A leftover Job from a previous attempt has an immutable pod template, so a
  # re-apply under the same name fails. Drop it first.
  local job
  while read -r job; do
    [[ -z "$job" ]] && continue
    echo "    deleting leftover ${job}"
    kubectl -n "$ns" delete "$job" --wait=true --timeout=60s >/dev/null 2>&1 || true
  done < <(kubectl -n "$ns" get jobs -o name 2>/dev/null | grep -i certgen || true)

  filter_kinds only Job <<<"$hooks" | rewrite_images | apply_stdin "$ns"

  # Success is the Secret and the caBundle, not the Job reporting complete:
  # the Job sets ttlSecondsAfterFinished: 30, so it can be garbage-collected
  # before or during a wait on its condition.
  echo "    waiting for certgen to write secret envoy-gateway and the caBundle"
  local elapsed=0 limit="${WAIT_TIMEOUT%s}"
  while :; do
    ca=$(kubectl get mutatingwebhookconfiguration "$webhook" \
      -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
    if kubectl -n "$ns" get secret envoy-gateway >/dev/null 2>&1 && [[ -n "$ca" ]]; then
      break
    fi
    if (( elapsed >= limit )); then
      kubectl -n "$ns" get jobs,pods >&2 2>/dev/null || true
      kubectl -n "$ns" logs -l app=certgen --tail=50 >&2 2>/dev/null || true
      die "certgen did not finish within ${limit}s"
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "    secret envoy-gateway and webhook caBundle are present"
  pause_between "$ns"
}

# Every namespace any step targets or references. Created up front because
# charts cross-reference namespaces owned by later steps, e.g.
# envoy-gateway-config (23) puts a ReferenceGrant in ai-gateway-system (36).
NAMESPACES=(
  cnpg-system appwrapper-system kyverno prometheus-system cert-manager
  opentelemetry-operator-system metallb-system external-secrets envoy-gateway-system
  cf-openbao otel-lgtm-stack keda envoy-ai-gateway-system kserve-system
  "$CF_AMD_GPU_NS" aim-system aiwb keycloak seaweedfs-operator
  seaweedfs-instance ai-gateway-system rabbitmq-system kueue-system
  kaiwo-system
)

if [[ "$DRY_RUN" -eq 0 ]]; then
  prepare_host
  echo "==> creating namespaces"
  for ns in "${NAMESPACES[@]}"; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  ensure_cluster_tls
fi

# 4.4.0a local-path provisioner & the StorageClass named "default"
#
# Of the four things Cluster-Forge's handler does, three are OpenShift's: the
# SCC, the helper-pod SELinux context, and relabelling the backing directory
# through oc debug. RKE2 ships rancher.io/local-path built in, so what is left
# is the StorageClass literally named "default" -- required by name, not by
# role, because otel-lgtm-stack's PVCs, the Keycloak CNPG cluster and the
# rabbitmq values all hardcode that string. Without it those PVCs stay Pending
# whatever the cluster default is.
#
# The upstream provisioner manifest is deliberately not fetched: it is a URL,
# and there is no network here. A cluster with no local-path provisioner at all
# needs one hauled in before this runs.
if should_run 1; then
  echo "==> 4.4.0a local-path storage"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! kubectl get storageclass local-path >/dev/null 2>&1 &&
       ! kubectl get storageclass default >/dev/null 2>&1; then
      echo "    WARNING: no local-path or default StorageClass, and the upstream" >&2
      echo "    provisioner manifest cannot be fetched in an air gap. PVCs will" >&2
      echo "    stay Pending until a provisioner is installed." >&2
    fi
    ensure_storageclass default
    # The default-class seat is claimed only when empty: a cluster that already
    # nominated one has real storage behind it, and that outranks this. Two
    # classes marked default would also be worse than none, since Kubernetes
    # breaks that tie by creation time.
    sc_defaults=$(kubectl get storageclass \
      -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
      2>/dev/null | grep '=true$' | cut -d= -f1 || true)
    if [[ -z "$sc_defaults" ]]; then
      kubectl patch storageclass default -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
      echo "    marked default as the cluster default StorageClass"
    else
      echo "    cluster default StorageClass is already $(echo "$sc_defaults" | paste -sd, -) - left alone"
    fi
  fi
  pause_between
fi

# 4.4.1 Kuberay operator (Cluster-Forge namespace is default)
if should_run 1; then
  apply_chart 4.4.1 kuberay-operator kuberay-operator 1.4.2 default --set "image.repository=${LOCAL_REG}/kuberay/operator" --set image.tag=v1.4.2
fi

# 4.4.2 CloudNativePG operator
if should_run 2; then
  apply_chart 4.4.2 cnpg-operator cloudnative-pg 0.26.0 cnpg-system
fi

# 4.4.3 AppWrapper
if should_run 3; then
  ensure_ns appwrapper-system
  apply_file 4.4.3 appwrapper-install.yaml appwrapper-system
fi

# 4.4.4 Kyverno
if should_run 4; then
  apply_chart 4.4.4 kyverno kyverno 3.5.1 kyverno --set webhooksCleanup.enabled=false --set reportsController.resources.limits.memory=1Gi --set reportsController.resources.requests.memory=256Mi
fi

# 4.4.5 Kyverno base policies
if should_run 5; then
  apply_chart 4.4.5 kyverno-policies-base kyverno-policies-base 1.0.0 kyverno
fi

# 4.4.6 Kyverno local-path storage policies
if should_run 6; then
  apply_chart 4.4.6 kyverno-policies-storage-local-path kyverno-policies-storage-local-path 1.0.0 kyverno
  # The step declares extraManifests as well as a chart; the policy scoping
  # local-path PVCs to ReadWriteOnce is only in the manifest.
  apply_file 4.4.6a 04-local-path-access-mode-scoped.yaml kyverno
fi

# 4.4.6b Workspace StorageClasses. multinode and mlstorage are aliases of
# local-path, not separate backends, created because charts and the storage
# policies name them.
if should_run 7; then
  echo "==> 4.4.6b workspace StorageClasses"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    ensure_storageclass multinode
    ensure_storageclass mlstorage
  fi
  pause_between
fi

# 4.4.7 Prometheus operator CRDs
if should_run 7; then
  apply_chart 4.4.7 prometheus-operator-crds prometheus-operator-crds 23.0.0 prometheus-system
fi

# 4.4.8 cert-manager
if should_run 8; then
  apply_chart 4.4.8 cert-manager cert-manager v1.18.2 cert-manager --set installCRDs=true
fi

# 4.4.9 OpenTelemetry operator
if should_run 9; then
  apply_chart 4.4.9 opentelemetry-operator opentelemetry-operator 0.93.1 opentelemetry-operator-system
fi

# 4.4.9b MetalLB controller/speaker, followed by the deployment-specific L2
# pool. The node's InternalIP is intentional on Cluster-Bloom/OCI: the public
# address is NATed to it, and MetalLB makes the Envoy LoadBalancer own :443.
if should_run 9; then
  echo "==> 4.4.9b MetalLB"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    prepare_metallb
  fi
  apply_file 4.4.9b metallb-native.yaml metallb-system
  if [[ "$DRY_RUN" -eq 0 ]]; then
    configure_metallb
  fi
fi

# 4.4.10 External Secrets operator
if should_run 10; then
  apply_chart 4.4.10 external-secrets external-secrets 0.19.2 external-secrets
fi

# 4.4.11 Gateway API and Envoy Gateway CRDs (chart name is crds)
if should_run 11; then
  apply_chart 4.4.11 envoy-gateway-crds crds 0.0.0 envoy-gateway-system
fi

# 4.4.12 OpenBao
if should_run 12; then
  apply_chart 4.4.12 openbao openbao 0.18.2 cf-openbao --set injector.enabled=false --set server.ha.enabled=false --set ui.enabled=true
fi

# 4.4.13 OpenBao configuration
if should_run 13; then
  apply_chart 4.4.13 openbao-config openbao-config 0.1.0 cf-openbao --set "domain=${CF_DOMAIN}" --set "minio.apiAccessKey=${MINIO_API_ACCESS_KEY}" --set "minio.consoleAccessKey=${MINIO_CONSOLE_ACCESS_KEY}"
fi

# 4.4.13b OpenBao init ConfigMap aliases. The init job mounts the two
# ConfigMaps of step 13 under different names, and nothing in the charts
# creates those names: values-openshift.yaml does it with step_copy_objects.
# Without them the init job pod never leaves ContainerCreating, OpenBao stays
# uninitialised and sealed, and the openbao-secret-manager CronJob fails every
# run looking for the openbao-keys Secret the init job would have written.
# Gated on 14 rather than 13 so --from 14 still gets its prerequisite.
if should_run 14; then
  copy_object 4.4.13b configmap openbao-secrets-config openbao-secrets-init-config cf-openbao
  copy_object 4.4.13b configmap openbao-secret-manager-scripts openbao-secret-manager-scripts-init cf-openbao
fi

# 4.4.14 OpenBao initialization job
if should_run 14; then
  apply_chart 4.4.14 openbao-init-job openbao-init-job 0.1.0 cf-openbao --set "domain=${CF_DOMAIN}"
fi

# 4.4.15 External Secrets configuration
if should_run 15; then
  apply_file 4.4.15 external-secrets-openbao-secret-store.yaml
fi

# 4.4.16 OpenTelemetry LGTM stack (Chart.yaml version 1.0.8 even if packed from v1.0.7 dir)
if should_run 16; then
  apply_chart 4.4.16 otel-lgtm-stack otel-lgtm-stack 1.0.8 otel-lgtm-stack --set "cluster.name=${CF_DOMAIN}" --set collectors.resources.metrics.requests.cpu=500m --set collectors.resources.metrics.requests.memory=1Gi --set collectors.resources.metrics.limits.memory=4Gi --set collectors.resources.logs.requests.cpu=250m --set collectors.resources.logs.requests.memory=256Mi --set collectors.resources.logs.limits.cpu=1 --set collectors.resources.logs.limits.memory=1Gi --set dashboards.enabled=true --set kubeStateMetrics.enabled=true --set nodeExporter.enabled=true --set services.nodeExporter.metrics=9110 --set lgtm.resources.requests.cpu=1 --set lgtm.resources.requests.memory=2Gi --set lgtm.resources.limits.memory=8Gi --set lgtm.storage.grafana=10Gi --set lgtm.storage.loki=50Gi --set lgtm.storage.mimir=50Gi --set lgtm.storage.tempo=50Gi --set lgtm.storage.extra=50Gi
fi

# 4.4.17 KEDA
if should_run 17; then
  apply_chart 4.4.17 keda keda 2.18.1 keda
fi

# 4.4.18 Kedify OpenTelemetry scaler
if should_run 18; then
  apply_chart 4.4.18 kedify-otel otel-add-on v0.0.6 keda --set validatingAdmissionPolicy.enabled=false
fi

# 4.4.18b AI gateway base objects: the GatewayClass, the https and ai-gateway
# Gateways, and the backend TLS policy the routes attach to.
# The file is shared with the OpenShift path, so it also carries an SCC and a
# Route. Neither kind exists here, and kubectl fails the whole apply on an
# unknown kind rather than skipping it.
if should_run 19; then
  CHART_KINDS="exclude SecurityContextConstraints Route"
  apply_objects 4.4.18b 06-ai-gateway.yaml envoy-gateway-system
fi

# 4.4.19 Inference Extension CRDs
if should_run 19; then
  apply_chart 4.4.19 inference-extension-crds inference-extension-crds v1.5.0 envoy-ai-gateway-system
fi

# 4.4.20 Envoy AI Gateway CRDs
if should_run 20; then
  apply_chart 4.4.20 envoy-ai-gateway-crds ai-gateway-crds-helm v1.0.0 envoy-ai-gateway-system
fi

# 4.4.21a Envoy Gateway certgen. The chart mints Secret envoy-gateway with a
# Helm pre-install Job. apply_chart uses --no-hooks so Kyverno's hooks cannot
# scale the operator to zero, which also skips this Job, and the controller
# then sits in ContainerCreating: secret "envoy-gateway" not found. Render
# without --no-hooks, keep only the certgen objects, wait for the Job, then
# install the rest of the chart as usual.
if should_run 21; then
  apply_envoy_certgen
fi

# 4.4.21 Envoy Gateway
# global.images.envoyProxy.image is what the controller uses for data-plane
# pods; helm template of this chart does not emit those Deployments.
if should_run 21; then
  apply_chart 4.4.21 envoy-gateway gateway-helm v1.8.1 envoy-gateway-system \
    --set "global.images.envoyProxy.image=${LOCAL_REG}/envoyproxy/envoy:distroless-v1.38.1"
fi

# 4.4.22 Envoy AI Gateway
if should_run 22; then
  apply_chart 4.4.22 envoy-ai-gateway ai-gateway-helm 1.0.0 envoy-ai-gateway-system --set controller.mutatingWebhook.certManager.enable=true --set "controller.mcp.sessionEncryption.seed=${AI_GATEWAY_MCP_SEED}"
fi

# 4.4.23 Envoy Gateway configuration
if should_run 23; then
  apply_chart 4.4.23 envoy-gateway-config envoy-gateway-config 0.1.0 envoy-gateway-system \
    --set "domain=${CF_DOMAIN}" \
    --set appsGateway.serviceType=LoadBalancer \
    --set aiGateway.enabled=true \
    --set "aiGateway.routeHostname=ai.${CF_DOMAIN}" \
    --set aiGateway.discoveryNamespace=ai-gateway-system \
    --set aiGateway.bodyAuthMaxRequestBytes=4194304
  wait_gateway_address
fi

# Gated on 24 so --from 24 still patches Gateways created in 23.
if should_run 24; then
  patch_envoy_proxy_images
fi

# 4.4.23b AI gateway webhook health. The pod mutating webhook runs with
# failurePolicy: Fail and matches Envoy data-plane pods, so a caBundle out of
# sync with the controller's TLS secret blocks those pods from being created
# at all. The hauled script probes it and re-syncs if needed.
if should_run 24; then
  echo "==> 4.4.23b ai-gateway webhook health"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    probe=$(store_file ai-gateway-webhook-health.sh) || probe=""
    if [[ -n "$probe" ]]; then
      bash "$probe" || echo "    WARNING: webhook probe reported a problem it could not heal" >&2
    else
      echo "    WARNING: ai-gateway-webhook-health.sh is not in this store - skipping" >&2
    fi
  fi
  pause_between envoy-ai-gateway-system
fi

# 4.4.24 KServe CRDs
if should_run 24; then
  apply_chart 4.4.24 kserve-crds kserve-crd v0.16.0 kserve-system
fi

# 4.4.25 KServe controller. Cluster-Forge applies this chart twice and splits
# it by kind: the ClusterServingRuntimes are custom resources of a webhook this
# same chart installs, so applying them together is a race the first apply
# loses until the controller is up and its caBundle is populated.
if should_run 25; then
  CHART_KINDS="exclude ClusterServingRuntime"
  apply_chart 4.4.25 kserve kserve v0.16.0 kserve-system --set kserve.controller.deploymentMode=Standard --set kserve.controller.gateway.ingressGateway.enableGatewayApi=false --set kserve.localmodel.enabled=false
fi

# 4.4.25b KServe serving runtimes: the other half of the same chart.
if should_run 26; then
  CHART_KINDS="only ClusterServingRuntime"
  apply_chart 4.4.25b kserve kserve v0.16.0 kserve-system --set kserve.controller.deploymentMode=Standard --set kserve.controller.gateway.ingressGateway.enableGatewayApi=false --set kserve.localmodel.enabled=false
fi

# 4.4.26 AMD GPU Operator and CRDs
if should_run 26; then
  apply_chart 4.4.26 amd-gpu-operator gpu-operator-charts v1.4.1 "$CF_AMD_GPU_NS" --set crds.defaultCR.install=false
fi

# 4.4.27 AMD GPU Operator configuration
#
# Cluster-Forge passes --set namespace=${CF_AMD_GPU_NS} here, which the v1.4.1
# chart ignores: every template reads .Release.Namespace. The value that
# matters is the release namespace, so this installs into CF_AMD_GPU_NS
# instead of hardcoding one. It is the namespace the metrics collector's
# scrape config is built from, and a job pointed at the wrong one finds no
# targets and reports nothing while the collector stays 1/1.
if should_run 27; then
  apply_chart 4.4.27 amd-gpu-operator-config amd-gpu-operator-config 0.1.0 "$CF_AMD_GPU_NS"
fi

# 4.4.27b AMD GPU NodeFeatureRule: the labels node-feature-discovery applies to
# nodes carrying AMD GPUs, which the operator's DaemonSets select on.
if should_run 28; then
  apply_objects 4.4.27b 08-amd-gpu-nodefeaturerule.yaml "$CF_AMD_GPU_NS"
fi

# 4.4.28 AIM Engine CRDs
if should_run 28; then
  apply_chart 4.4.28 aim-engine-crds aim-engine-crds-chart 0.2.5 aim-system
fi

# 4.4.29 AIM Engine
if should_run 29; then
  apply_chart 4.4.29 aim-engine aim-engine-chart 0.2.5 aim-system --set clusterRuntimeConfig.enable=false
fi

# 4.4.29b AI Workbench base objects: the namespaces AIWB, Keycloak and MinIO
# live in, plus the Keycloak and object-store credentials the later charts
# reference by name. Namespaces among them, so this cannot wait until 4.4.35.
if should_run 30; then
  apply_objects 4.4.29b objects-aiwb-infra.yaml
fi

# 4.4.29c/d Database credentials, in whichever shape this deployment uses.
# Cluster-Forge skips each by the same condition: the CNPG superuser secrets
# only make sense when the cluster runs its own PostgreSQL, and the plain
# db-user secrets only when it is pointed at one that already exists.
if should_run 30 && [[ "$PLUGGABLE_DB" != true ]]; then
  apply_objects 4.4.29c objects-aiwb-infra-cnpg-secrets.yaml
fi
if should_run 30 && [[ "$PLUGGABLE_DB" == true ]]; then
  apply_objects 4.4.29d objects-aiwb-infra-db-secrets.yaml
fi

# 4.4.29e cluster-auth shim: a stock python image running a mounted script,
# standing in for the cluster-auth operator. AIWB reads the admin token it
# serves, so it has to exist before 4.4.35.
if should_run 30; then
  apply_objects 4.4.29e objects-cluster-auth-shim.yaml cluster-auth
fi

# 4.4.30 AI Workbench CNPG infrastructure (PLUGGABLE_DB=false)
if should_run 30 && [[ "$PLUGGABLE_DB" != true ]]; then
  apply_chart 4.4.30 aiwb-infra-cnpg aiwb-cnpg-chart 2.0.0 aiwb --set instances=1 --set "username=${AIWB_DB_USER}" --set "storage.storageClass=${CF_STORAGE_CLASS}" --set "walStorage.storageClass=${CF_STORAGE_CLASS}"
fi

# 4.4.31 Keycloak with its own CNPG database (PLUGGABLE_DB=false)
if should_run 31 && [[ "$PLUGGABLE_DB" != true ]]; then
  apply_chart 4.4.31 keycloak keycloak-old 0.2.0 keycloak --set "domain=${CF_DOMAIN}" --set "hostname=${KC_URL}" --set externalSecrets.enabled=false --set cnpg.enabled=true --set cnpg.instances=1 --set "cnpg.storage.storageClassName=${CF_STORAGE_CLASS}" --set "postgresql.username=${KEYCLOAK_DB_USER}"
fi

# 4.4.31b Keycloak against a database the cluster does not run
# (PLUGGABLE_DB=true). Same chart and release as 4.4.31, so only one of the
# two ever applies.
if should_run 32 && [[ "$PLUGGABLE_DB" == true ]]; then
  apply_chart 4.4.31b keycloak keycloak-old 0.2.0 keycloak --set "domain=${CF_DOMAIN}" --set "hostname=${KC_URL}" --set externalSecrets.enabled=false --set cnpg.enabled=false --set "postgresql.host=${POSTGRES_HOST}" --set "postgresql.port=${POSTGRES_PORT}" --set "postgresql.database=${KEYCLOAK_DB_NAME}" --set "postgresql.username=${KEYCLOAK_DB_USER}" --set postgresql.userSecretName=keycloak-db-user
fi

# 4.4.32 SeaweedFS CRDs come from the operator chart in 0.1.36 (crds.create),
# so there is no separate CRD step. See 3.32.

# 4.4.33 SeaweedFS operator (PLUGGABLE_S3=false)
if should_run 33 && [[ "$PLUGGABLE_S3" != true ]]; then
  apply_chart 4.4.33 seaweedfs-operator seaweedfs-operator 0.1.36 seaweedfs-operator --set "domain=${CF_DOMAIN}" --set webhook.enabled=false
fi

# 4.4.33b SeaweedFS S3 credentials. The Seaweed CR that 4.4.34 creates mounts
# seaweedfs-s3-config, so the Secret has to exist before the CR does.
if should_run 34 && [[ "$PLUGGABLE_S3" != true ]]; then
  apply_objects 4.4.33b objects-seaweedfs-secrets.yaml seaweedfs-instance
fi

# 4.4.34 SeaweedFS configuration (PLUGGABLE_S3=false)
if should_run 34 && [[ "$PLUGGABLE_S3" != true ]]; then
  apply_chart 4.4.34 seaweedfs-config seaweedfs-config 0.1.0 seaweedfs-instance --set "domain=${CF_DOMAIN}" --set "seaweed.storageClassName=${CF_STORAGE_CLASS}" --set 'initJob.buckets[0].name=default-bucket' --set 'initJob.buckets[1].name=models' --set 'initJob.buckets[2].name=datasets'
fi

# 4.4.34b Redirect Service standing in for the in-cluster object store when one
# already exists outside it (PLUGGABLE_S3=true). Endpoints written by hand,
# which is why MINIO_HOST_IP is an address rather than a name.
if should_run 35 && [[ "$PLUGGABLE_S3" == true ]]; then
  apply_objects 4.4.34b objects-minio-external-redirect.yaml minio-tenant-default
fi

# 4.4.35 AI Workbench
#
# Image tag and repository overrides are left off deliberately. Cluster-Forge
# gates each on `when: CF_AIWB_..._IMAGE_TAG`, so they are opt-in overrides
# rather than part of the install, and pointing the chart at a tag other than
# its default would name an image the haul does not contain.
if should_run 35; then
  aiwb_args=(
    --set standAloneMode=true
    --set "appDomain=${CF_DOMAIN}"
    --set "backend.clusterHost=${AIWB_UI_URL}"
    --set "frontend.env.NEXTAUTH_URL=${AIWB_UI_URL}"
    --set "keycloak.url=${KC_URL}"
    --set "frontend.env.KEYCLOAK_ISSUER=${KC_URL}/realms/airm"
    --set "postgresql.username=${AIWB_DB_USER}"
    # AIWB UI/API are ordinary app routes on the external apps Gateway. The
    # dedicated ai-gateway is ClusterIP-only and has default-deny inference
    # authorization, so parenting UI routes to it returns RBAC: access denied.
    --set gateway.namespace=envoy-gateway-system
    --set gateway.gatewayName=https
    --set aim.routing.enabled=false
  )
  if [[ "$PLUGGABLE_S3" == true ]]; then
    aiwb_args+=(--set "minio.url=http://${MINIO_HOST}:${MINIO_PORT}" --set "minio.bucket=${MINIO_BUCKET}")
  fi
  if [[ "$PLUGGABLE_DB" == true ]]; then
    aiwb_args+=(--set "postgresql.host=${POSTGRES_HOST}" --set "postgresql.port=${POSTGRES_PORT}" --set "postgresql.database=${AIWB_DB_NAME}" --set postgresql.userSecretName=aiwb-db-user)
  fi
  apply_chart 4.4.35 aiwb aiwb-chart 2.0.0 aiwb "${aiwb_args[@]}"
fi

# 4.4.36 AI Gateway Discovery
if should_run 36; then
  apply_chart 4.4.36 ai-gateway-discovery ai-gateway-discovery-chart 2.0.0 ai-gateway-system --set "controller.gateway.routeHostname=ai.${CF_DOMAIN}" --set controller.gateway.name=ai-gateway --set controller.bodyAuthMaxRequestBytes=4194304
fi

# 4.4.37 RabbitMQ Cluster Operator
if should_run 37; then
  ensure_ns rabbitmq-system
  apply_file 4.4.37 rabbitmq-cluster-operator.yaml rabbitmq-system
fi

# 4.4.38 Kueue (Chart.yaml version 0.13.3 from the 0.13.0 source dir)
if should_run 38; then
  apply_chart 4.4.38 kueue kueue 0.13.3 kueue-system
fi

# 4.4.39 Kueue configuration
if should_run 39; then
  apply_file 4.4.39 kueue-cluster-role-binding.yaml
fi

# 4.4.40 Kaiwo CRDs
if should_run 40; then
  apply_chart 4.4.40 kaiwo-crds kaiwo-crds-chart v0.2.1 kaiwo-system
fi

# 4.4.41 Kaiwo operator
if should_run 41; then
  apply_chart 4.4.41 kaiwo kaiwo-operator-chart v0.2.1 kaiwo-system
fi

# 4.4.42 Kaiwo configuration
if should_run 42; then
  apply_file 4.4.42 kaiwo-pvc-user-demo.yaml
  apply_file 4.4.42 kaiwo-minio-credentials.yaml
fi

# 4.4.43 AIM cluster model source (catalog images only if the haul used all-model-images)
if should_run 43; then
  # Instinct or Radeon model catalogue, discovered from the labels the GPU
  # operator's node labeller writes. Nothing is passed when no GPU node is
  # labelled, so the chart keeps its own default rather than being handed an
  # empty string.
  families="${AIM_HARDWARE_FAMILY:-}"
  if [[ -z "$families" && "$DRY_RUN" -eq 0 ]]; then
    products=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.amd\.com/gpu\.product-name}{"\n"}{end}' 2>/dev/null | tr 'A-Z' 'a-z' | sort -u)
    grep -q instinct <<<"$products" && families="instinct"
    grep -q radeon <<<"$products" && families="${families:+${families},}radeon"
  fi
  if [[ -n "$families" ]]; then
    echo "    AIM hardware families: ${families}"
    apply_chart 4.4.43 aim-cluster-model-source aim-cluster-model-source 0.1.0 kaiwo-system --set "hardwareFamilies=${families}"
  else
    apply_chart 4.4.43 aim-cluster-model-source aim-cluster-model-source 0.1.0 kaiwo-system
  fi
fi

# What used to be "4.4.44, not in the haul" is now the lettered steps above:
# hauler.sh renders the inline extraObjects to files, so the only Cluster-Forge
# steps still missing here are the ones that are OpenShift's alone -- the SCCs,
# the OpenShift Kyverno policies, the router wildcard certificate copy, and the
# Routes.

# Same wrap-up install.sh prints, with the RKE2 hostnames (kc / aiwbui /
# ai.<domain>) instead of the OpenShift router :8080 URL.
print_access_details() {
  echo ""
  echo "Inference endpoint (all served models share this hostname):"
  echo "   https://${AI_HOST}/v1/chat/completions"
  echo ""
  echo "   Which model answers is decided by the headers, not the path or host."
  echo "   -k is needed if the listener still serves an untrusted certificate."
  echo ""
  echo "   curl -k -X POST https://${AI_HOST}/v1/chat/completions \\"
  echo "     -H 'Content-Type: application/json' \\"
  echo "     -H 'x-ai-eg-backend: <workload-uuid>' \\"
  echo "     -H 'x-ai-eg-model: <model-name>' \\"
  echo "     -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":false}'"
  echo ""
  echo "   Routes appear on their own as models are deployed; the UUID is the"
  echo "   InferenceService workload-id label:"
  echo "     kubectl get inferenceservice -A -o custom-columns=\\"
  echo "       'NAME:.metadata.name,UUID:.metadata.labels.airm\\.silogen\\.ai/workload-id'"
  echo "     kubectl get aigatewayroute,aiservicebackend -A"
  echo ""
  echo "Keycloak Admin Credentials:"
  echo "   Username: silogen-admin"
  echo "   Password: ${KEYCLOAK_INITIAL_ADMIN_PASSWORD}"
  echo "   Admin Console: ${KC_URL}/admin"
  echo ""
  echo "AIWB User Login:"
  echo "   UI: ${AIWB_UI_URL}"
  echo "   Username: devuser@${DOMAIN}"
  echo "   Password: ${KEYCLOAK_INITIAL_DEVUSER_PASSWORD}"
  echo ""
  echo "Observability (Grafana, Prometheus, Loki, Tempo):"
  echo "   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000"
  echo "   Access Grafana at: http://localhost:3000"
  echo "   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090"
  echo "   Access Prometheus at: http://localhost:9090"
  echo ""
}

print_access_details
echo "done"
