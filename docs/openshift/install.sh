#!/bin/bash

# Install cluster-forge apps on OpenShift one app at a time.
#
# Successor to install-old.sh, the previous hardcoded installer. This
# script walks root/values-openshift.yaml so each app is applied and verified on its
# own. install-old.sh is kept for comparison.

set -euo pipefail

# --help must not download a release or talk to the cluster. Parsed here, before
# any of that; the rest of the flags wait until the values file is loaded.
if [ "${CF_LIB_ONLY:-false}" != "true" ]; then
  for _cf_arg in "$@"; do
    case "${_cf_arg}" in
      -h|--help)
        cat <<'EOF'
Usage: install.sh [options] [app ...]

Walks root/values-openshift.yaml and installs each app in declaration order.

  --list              print the install order and exit
  -h, --help          this

Positional arguments (or CF_ONLY) name the only apps to install, by their key
in values-openshift.yaml. Example:

  CF_VERSION_AIWB=2.0.1 ./docs/openshift/install.sh aiwb

Set PLUGGABLE_DB, PLUGGABLE_S3 and CF_VERSION_* the same way as a full install:
they decide which steps exist and which chart version each one renders from.
EOF
        exit 0
        ;;
    esac
  done
  CF_START_EPOCH="${CF_START_EPOCH:-$(date +%s)}"
fi

# ============================================================================
# HELPERS
# ============================================================================
# On heavily-loaded clusters the API server and GitHub intermittently time out.
# With `set -e` a single blip aborts the whole run, so transient failures are
# retried with a fixed backoff instead.
RETRY_MAX="${RETRY_MAX:-6}"
RETRY_DELAY="${RETRY_DELAY:-15}"
# Busy API servers intermittently return "the server was unable to return a
# response in the time allotted"; give each request longer than the default.
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

# Wall-clock since CF_START_EPOCH. Printed at the end of install, and by
# uninstall-all.sh after it sources this file as a library.
cf_print_elapsed() {
  local elapsed h m s
  elapsed=$(( $(date +%s) - CF_START_EPOCH ))
  h=$((elapsed / 3600))
  m=$(( (elapsed % 3600) / 60 ))
  s=$((elapsed % 60))
  if [ "${h}" -gt 0 ]; then
    echo "⏱️  Elapsed: ${h}h ${m}m ${s}s"
  elif [ "${m}" -gt 0 ]; then
    echo "⏱️  Elapsed: ${m}m ${s}s"
  else
    echo "⏱️  Elapsed: ${s}s"
  fi
}

# The field manager every apply runs as, reset to cluster-forge/<app> before each
# step. It matters because server-side apply tracks ownership per manager and prunes
# the fields a manager used to set and no longer does: two steps applying the same
# object under one manager name delete each other's fields, while under two names they
# merge. Both cases happen here -- the AIM Engine and AIWB charts each create
# AIMClusterRuntimeConfig "default" with different halves of its spec -- and install-old.sh
# gets the first case, because every one of its applies is the kubectl default manager
# "kubectl". So the last step to touch a shared object silently strips what the earlier
# one configured, which is how the routing setting install-old.sh deliberately sets on
# OpenShift ends up absent from the object by the end of a run.
CF_FIELD_MANAGER="cluster-forge"

# ssa_apply [extra kubectl args...] : server-side apply from stdin with a long
# request timeout and retries. Captures stdin so each retry re-feeds the same
# manifests (a plain `| kubectl apply` cannot be retried once stdin is consumed).
# --force-conflicts: many objects on these clusters still carry stale
# managedFields ownership from a removed ArgoCD, and server-side apply refuses
# with "Apply failed with N conflicts" unless the ownership is taken over.
ssa_apply() {
  local manifests n=1 rc=0
  manifests="$(cat)"
  while true; do
    if printf '%s' "${manifests}" | kubectl apply --server-side --force-conflicts \
        --field-manager="${CF_FIELD_MANAGER}" \
        --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" "$@" -f -; then
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

# step <description> : print a numbered banner for the next phase. The counter
# increments at runtime, so the output shows exactly which phases were reached
# and in what order.
STEP=0
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "════════════════ [STEP ${STEP}] $* ════════════════"
}

# ============================================================================
# EGRESS PROXY
# ============================================================================
# Clusters behind a corporate firewall reach GitHub and the OCI registries
# through a proxy. It is configured with one variable, CF_PROXY_URL, which is
# mapped onto the conventional per-tool variables below:
#
#     CF_PROXY_URL=http://proxy.corp:3128 ./install.sh
#
# One variable rather than expecting callers to export the standard ones,
# because the tools this script drives do not agree on which spelling they read
# and the failure is silent either way. GNU wget honours only the lowercase
# http_proxy/https_proxy (verified on 1.21.4 — with HTTPS_PROXY set and nothing
# else, it ignores the proxy and connects straight out), whereas kubectl and
# helm follow the Go convention and prefer the uppercase names. An environment
# with only one case set therefore proxies some steps and not others, which
# presents as a single hanging download in the middle of a working run.
#
# Credentials belong in the URL (http://user:pass@proxy.corp:3128) and are
# redacted from the log line below, since this output tends to end up in
# tickets.
CF_PROXY_URL="${CF_PROXY_URL:-}"

# Destinations that must bypass the proxy. Loopback and the in-cluster DNS
# suffixes are always included: once a proxy is set, kubectl and helm would
# otherwise send API-server and in-cluster Service traffic to it too, and an
# egress proxy cannot route to a private cluster address. Extend for your
# environment (the API server's own hostname usually belongs here) with:
#
#     CF_NO_PROXY=api.mycluster.example.com,10.0.0.0/8
#
CF_NO_PROXY="${CF_NO_PROXY:-}"
CF_NO_PROXY_DEFAULTS="localhost,127.0.0.1,::1,.svc,.svc.cluster.local,.cluster.local"

if [ -n "${CF_PROXY_URL}" ]; then
  case "${CF_PROXY_URL}" in
    http://*|https://*) ;;
    *)
      echo "❌ CF_PROXY_URL must include a scheme, e.g. http://proxy.corp:3128" >&2
      echo "   Got: ${CF_PROXY_URL}" >&2
      exit 1
      ;;
  esac

  # Both cases of every variable, for the reason given above.
  http_proxy="${CF_PROXY_URL}"
  https_proxy="${CF_PROXY_URL}"
  HTTP_PROXY="${CF_PROXY_URL}"
  HTTPS_PROXY="${CF_PROXY_URL}"
  no_proxy="${CF_NO_PROXY:+${CF_NO_PROXY},}${CF_NO_PROXY_DEFAULTS}"
  NO_PROXY="${no_proxy}"
  export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY

  echo "ℹ️  Using egress proxy: $(printf '%s' "${CF_PROXY_URL}" | sed -E 's#(://)[^@/]+@#\1***:***@#')"
  echo "ℹ️  Bypassing proxy for: ${no_proxy}"
fi

# ============================================================================
# REQUIRED TOOLING
# ============================================================================
# Checked up front so a missing tool fails in a second rather than halfway
# through a cluster mutation. Extra tools are acceptable here: this script is
# destined to run inside a purpose-built operator image where they are baked in.
#
# yq must be the Go implementation (mikefarah). The similarly named Python "yq"
# wrapper takes different flags and would fail confusingly on every query. The
# repo already depends on the Go one — scripts/bootstrap.sh merges values files
# with `yq eval-all '. as $item ireduce ({}; . * $item)'`, which is v4 syntax.
require_tools() {
  local missing=0 t
  for t in kubectl helm yq curl wget tar; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      echo "❌ required tool not found in PATH: ${t}" >&2
      missing=1
    fi
  done
  [ "${missing}" -eq 0 ] || exit 1

  if ! yq --version 2>&1 | grep -qE 'mikefarah|version v4'; then
    {
      echo "❌ yq is not the expected implementation."
      echo "   Need the Go yq (github.com/mikefarah/yq) v4; found:"
      echo "     $(yq --version 2>&1)"
    } >&2
    exit 1
  fi
}
require_tools

# ============================================================================
# EXTRA MANIFESTS
# ============================================================================
# The SCC, Kyverno policy and Route manifests are not in the release tarball;
# they live in extra/ next to this script. Resolved exactly the way install-old.sh
# resolves them, so both scripts apply the same files.
#
# When piped (curl ... | bash) BASH_SOURCE is unset and $0 is "bash", so there
# is no script directory to hang extra/ off. Resolving one anyway would yield
# $PWD/extra and scatter downloads through whatever directory the operator
# happened to be standing in, so detect that case and stage in a temp dir
# instead; ensure_extra_file() fetches what it needs on demand.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
else
  SCRIPT_DIR=""
fi

if [ -n "${EXTRA_DIR:-}" ]; then
  echo "ℹ️  Using EXTRA_DIR override: ${EXTRA_DIR}"
elif [ -n "${SCRIPT_DIR}" ] && [ -d "${SCRIPT_DIR}/extra" ]; then
  EXTRA_DIR="${SCRIPT_DIR}/extra"
else
  EXTRA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cf-openshift-extra.XXXXXX")"
  CF_EXTRA_DIR_TEMP="${EXTRA_DIR}"
  echo "ℹ️  No local extra/ directory; staging manifests in ${EXTRA_DIR}"
fi

# Scratch space for what gets rendered on the fly, currently the valuesObject
# blocks handed to helm as --values files. Cleaned up together with the staged
# extra/ directory through one function behind one trap, since a second `trap
# ... EXIT` replaces the first rather than adding to it.
CF_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cf-openshift-work.XXXXXX")"
cf_cleanup() {
  rm -rf "${CF_WORK_DIR}"
  [ -n "${CF_EXTRA_DIR_TEMP:-}" ] && rm -rf "${CF_EXTRA_DIR_TEMP}"
  return 0
}
trap cf_cleanup EXIT

# Pinned to main deliberately: a piped run of this script comes from main, so
# the manifests it fetches must be the ones on main too.
EXTRA_RAW_BASE="https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/extra"

# ensure_extra_file <path under EXTRA_DIR> : guarantee the manifest is on disk,
# fetching it from ${EXTRA_RAW_BASE} when it is not. The filename is also the
# remote name, so extra/ here and extra/ on main must keep the same names.
#
# Fetch failure is fatal rather than a warning: several of these manifests are
# load-bearing, and a run that skipped one comes up subtly broken long after the
# warning scrolled past.
ensure_extra_file() {
  local f="$1" base url
  base="$(basename "${f}")"
  [ -f "${f}" ] && return 0

  url="${EXTRA_RAW_BASE}/${base}"
  # stage_extra_file captures stdout as the path it will apply. Keep progress
  # messages on stderr so a piped run does not mistake this text for a filename.
  echo "ℹ️  ${base} not present in ${EXTRA_DIR}; fetching from cluster-forge main..." >&2
  mkdir -p "$(dirname "${f}")"
  if ! retry curl -fsSL "${url}" -o "${f}" >&2; then
    rm -f "${f}"   # curl -f can leave an empty file behind on HTTP errors
    {
      echo "❌ Could not obtain required manifest: ${base}"
      echo "   Not in ${EXTRA_DIR}, and the fetch failed:"
      echo "     ${url}"
      echo ""
      echo "   Run from a checkout that has it, or point EXTRA_DIR at a"
      echo "   directory that does."
    } >&2
    exit 1
  fi
}

# Pinned to main for the same reason EXTRA_RAW_BASE is: a piped run of this script
# comes from main, so the files it fetches are main's too.
REPO_RAW_BASE="https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main"

# ensure_repo_file <path from the repository root> : print the local path of a file
# that lives in the cluster-forge repository but not in the release tarball, fetching
# it when this is not a checkout.
#
# For the files a step needs verbatim and which are not manifests: currently the
# cluster-auth shim's Python, which install-old.sh fetches the same way from
# docs/manual_helm_install/. Fetched rather than copied into this repository twice,
# because it is a program -- two copies of a program diverge quietly, and the symptom
# is an API stub that answers one endpoint wrongly.
ensure_repo_file() {
  local rel="$1" checkout="" staged url
  if [ -n "${SCRIPT_DIR}" ]; then
    checkout="${SCRIPT_DIR}/../../${rel}"
  fi
  if [ -n "${checkout}" ] && [ -f "${checkout}" ]; then
    printf '%s' "${checkout}"
    return 0
  fi

  staged="${CF_WORK_DIR}/repo/${rel}"
  if [ -f "${staged}" ]; then
    printf '%s' "${staged}"
    return 0
  fi

  url="${REPO_RAW_BASE}/${rel}"
  echo "ℹ️  ${rel} not in a checkout; fetching from cluster-forge main..." >&2
  mkdir -p "$(dirname "${staged}")"
  if ! retry curl -fsSL "${url}" -o "${staged}" >&2; then
    rm -f "${staged}"
    {
      echo "❌ Could not obtain required file: ${rel}"
      echo "   The fetch failed: ${url}"
      echo "   Run from a cluster-forge checkout that has it."
    } >&2
    exit 1
  fi
  printf '%s' "${staged}"
}

# ============================================================================
# CLUSTER-FORGE RELEASE
# ============================================================================
# Download a pinned cluster-forge release tarball instead of cloning a branch.
# CLUSTER_FORGE_VERSION selects the GitHub release (e.g. v2.2.2). The release
# asset "release-enterprise-ai-<version>.tar.gz" unpacks into a top-level
# "cluster-forge/" directory that contains root/, scripts/ and sources/ — but
# NOT docs/, so anything that used to live under docs/ has to be sourced
# elsewhere as apps get added to this script.
CLUSTER_FORGE_VERSION="${CLUSTER_FORGE_VERSION:-v2.2.2}"
CLUSTER_FORGE_DIR="${CLUSTER_FORGE_DIR:-/tmp/cluster-forge}"

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
CF_ROOT_DIR="${CLUSTER_FORGE_DIR}/cluster-forge/root"
# Every app's default details — chart path or OCI coordinates, namespace, values.
CF_ROOT_VALUES="${CF_ROOT_DIR}/values.yaml"
# The OpenShift install order, and any per-app overrides of the above.
CF_OPENSHIFT_VALUES="${CF_ROOT_DIR}/values-openshift.yaml"

# Assert the layout instead of trusting it: a release whose asset has a
# different internal structure would otherwise fail much later, in a helm
# install, with an error that says nothing about the download.
for p in "${SOURCES_DIR}" "${CF_ROOT_VALUES}"; do
  if [ ! -e "${p}" ]; then
    echo "❌ ${p} not found after extracting ${RELEASE_TARBALL}" >&2
    echo "   The release asset layout is not what this script expects." >&2
    exit 1
  fi
done

echo "✅ Sources extracted to ${SOURCES_DIR}"

# values-openshift.yaml belongs in the release tarball under root/. Older tarballs
# may not ship it yet; fetch the copy on main (same pin as REPO_RAW_BASE) into
# the extracted release tree so everything below reads one canonical path.
if [ ! -f "${CF_OPENSHIFT_VALUES}" ]; then
  echo "ℹ️  values-openshift.yaml is not in the ${CLUSTER_FORGE_VERSION} tarball; fetching from cluster-forge main..."
  if ! retry curl -fsSL "${REPO_RAW_BASE}/root/values-openshift.yaml" -o "${CF_OPENSHIFT_VALUES}"; then
    rm -f "${CF_OPENSHIFT_VALUES}"
    {
      echo "❌ ${CF_OPENSHIFT_VALUES} not found in the release and could not be fetched."
      echo "   Tried: ${REPO_RAW_BASE}/root/values-openshift.yaml"
    } >&2
    exit 1
  fi
fi

# Key order in the file is the install order, so read the keys in document
# order. Empty would mean the loop below silently installs nothing.
mapfile -t CF_APPS < <(yq '.apps | keys | .[]' "${CF_OPENSHIFT_VALUES}")
if [ "${#CF_APPS[@]}" -eq 0 ]; then
  echo "❌ no apps declared under apps: in ${CF_OPENSHIFT_VALUES}" >&2
  exit 1
fi
echo "✅ Install order loaded: ${#CF_APPS[@]} apps from $(basename "${CF_OPENSHIFT_VALUES}")"

# ============================================================================
# CLUSTER DOMAIN
# ============================================================================
# Every route and issuer URL the apps are configured with hangs off DOMAIN, so
# it is resolved once, here, and reused by each app step.
#
# Always read from the cluster itself, which states its ingress domain in
# ingresses.config.openshift.io/cluster (the same source install-old.sh reads).
# There is deliberately no override: the domain is a property of the target
# cluster, not a choice, and a hand-supplied value that disagrees with the
# ingress operator yields Routes that admit but never resolve.
#
# Select the cluster the ordinary way, with KUBECONFIG or the current context:
#
#     KUBECONFIG=docs/openshift/kube.yaml ./install.sh
#
step "Resolving cluster DOMAIN"

# Checked separately: with stderr discarded below, a missing kubectl and an
# OpenShift-less cluster both produce an empty DOMAIN, and guessing between
# them in the error message sends people to the wrong problem.
if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ kubectl not found in PATH, so the cluster domain cannot be read." >&2
  echo "   Install kubectl and re-run." >&2
  exit 1
fi

DOMAIN=$(kubectl get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null || true)

if [ -z "${DOMAIN}" ]; then
  {
    echo "❌ Could not read the cluster's ingress domain."
    echo ""
    echo "   Read from: ingresses.config.openshift.io/cluster -o jsonpath={.spec.domain}"
    echo "   That resource exists only on OpenShift, and reading it requires a"
    echo "   reachable cluster and permission on the config.openshift.io group."
    echo ""
    echo "   KUBECONFIG:      ${KUBECONFIG:-(unset, using ~/.kube/config)}"
    echo "   Current context: $(kubectl config current-context 2>/dev/null || echo '(none)')"
    echo ""
    echo "   Point KUBECONFIG at the OpenShift cluster and re-run."
  } >&2
  exit 1
fi

echo "✅ DOMAIN is ${DOMAIN}"

# The one hostname every served model answers on, with the model chosen per
# request from the x-ai-eg-backend and x-ai-eg-model headers. It needs a name of
# its own because an OpenShift Route can match on host and path but not on
# headers, so this is the hostname the Envoy AI Gateway serves rather than
# HAProxy.
AI_HOST="ai.${DOMAIN}"

# The two public URLs the platform is configured with, rather than merely reachable
# at: Keycloak issues its tokens for KC_URL and refuses a login redirected anywhere
# else, and AIWB's frontend signs users in against AIWB_UI_URL. They are derived once
# here because several steps have to agree on them -- Keycloak's own KC_HOSTNAME, the
# issuer AIWB's frontend validates against, the Routes that publish both -- and a
# disagreement between any two of those is an authentication failure rather than a
# missing page.
#
# https always, unlike install-old.sh, which also has a localhost shape on plain http with
# fixed ports. This script installs onto OpenShift, where DOMAIN is the router's
# wildcard domain and everything arrives through it over TLS.
KC_URL="https://kc.${DOMAIN}"
AIWB_UI_URL="https://aiwbui.${DOMAIN}"
export DOMAIN AI_HOST KC_URL AIWB_UI_URL

# ============================================================================
# AMD GPU OPERATOR NAMESPACE
# ============================================================================
# Where the AMD GPU operator runs, discovered the same way install-old.sh does it, by
# looking for its controller-manager Deployment.
#
# Needed because the metrics collector's scrape config hardcodes the upstream
# default namespace, kube-amd-gpu, and on OpenShift the operator is usually
# somewhere else -- openshift-amd-gpu when installed from the catalogue. A scrape
# job pointed at the wrong namespace finds no targets and reports nothing: the
# collector stays 1/1 and no gpu_* metric ever reaches Prometheus. So the value is
# resolved here and substituted into the render by the step that needs it.
#
# Resolved before the operator is installed, which is deliberate: the GPU operator
# comes later in this file, so on a first run there is nothing to find and the
# fallback is the namespace that step will create.
CF_AMD_GPU_NS="$(kubectl get deploy -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | awk '/amd-gpu-operator.*controller-manager/ {print $1; exit}' || true)"
CF_AMD_GPU_NS="${CF_AMD_GPU_NS:-amd-gpu-operator}"
export CF_AMD_GPU_NS
echo "✅ AMD GPU operator namespace is ${CF_AMD_GPU_NS}"

# ============================================================================
# AIM HARDWARE FAMILIES (lazy — read when aim-cluster-model-source runs)
# ============================================================================
# The aim-cluster-model-source chart selects Instinct vs Radeon model catalogs
# via hardwareFamilies. Cluster-bloom injects AIM_HARDWARE_FAMILY at deploy time;
# this script discovers the same choice from amd.com/gpu.product-name on GPU
# nodes, which the AMD GPU operator's node labeller sets after the operator steps.
#
# Called immediately before the aim-cluster-model-source install/uninstall step,
# not here: on a first run the labels do not exist until much later in the order.
discover_aim_hardware_families() {
  local -a families=() products product lower
  declare -A seen=()

  CF_AIM_HARDWARE_FAMILIES=""

  if [ -n "${AIM_HARDWARE_FAMILY:-}" ]; then
    CF_AIM_HARDWARE_FAMILIES="${AIM_HARDWARE_FAMILY}"
    export CF_AIM_HARDWARE_FAMILIES
    echo "✅ AIM hardware families ${CF_AIM_HARDWARE_FAMILIES} (from AIM_HARDWARE_FAMILY)"
    return 0
  fi

  mapfile -t products < <(
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.amd\.com/gpu\.product-name}{"\n"}{end}' 2>/dev/null \
      | sed '/^$/d' | sort -u
  )

  for product in "${products[@]}"; do
    lower="${product,,}"
    if [[ "${lower}" == *instinct* ]] && [ -z "${seen[instinct]:-}" ]; then
      families+=(instinct)
      seen[instinct]=1
    fi
    if [[ "${lower}" == *radeon* ]] && [ -z "${seen[radeon]:-}" ]; then
      families+=(radeon)
      seen[radeon]=1
    fi
  done

  CF_AIM_HARDWARE_FAMILIES="$(IFS=,; echo "${families[*]}")"
  export CF_AIM_HARDWARE_FAMILIES
  if [ -n "${CF_AIM_HARDWARE_FAMILIES}" ]; then
    echo "✅ AIM hardware families ${CF_AIM_HARDWARE_FAMILIES} (from amd.com/gpu.product-name)"
  fi
}

# ============================================================================
# STORAGE CLASS
# ============================================================================
# The class every step that provisions a volume asks for: the CNPG clusters behind
# AIWB and Keycloak, and SeaweedFS's volume server.
#
# install-old.sh takes the literal "default" with an env override, which is right on the
# clusters it was written for and wrong on any cluster whose default class is called
# something else -- and OpenShift's usually is, gp3-csi on AWS and ocs-storagecluster
# on ODF. A class name that does not exist does not fail the apply: the PVC is created,
# stays Pending, and the database sits in ContainerCreating with the reason two objects
# away from the step that caused it.
#
# So the cluster is asked which class is default, the same way DOMAIN and the GPU
# namespace are resolved above, and the literal is the fallback for a cluster that
# nominated none -- which is the state the local-path step earlier in this file exists
# to fix, and it names that class "default".
CF_STORAGE_CLASS="${DEFAULT_STORAGE_CLASS_NAME:-}"
if [ -z "${CF_STORAGE_CLASS}" ]; then
  CF_STORAGE_CLASS="$(kubectl get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1 || true)"
fi
CF_STORAGE_CLASS="${CF_STORAGE_CLASS:-default}"
export CF_STORAGE_CLASS
echo "✅ Storage class is ${CF_STORAGE_CLASS}"

# ============================================================================
# AIWB DEFAULT PROJECT ID
# ============================================================================
# The project the workbench namespace belongs to, as the label AIWB reads off it.
#
# The AIWB chart generates this with uuidv4 and tries to keep an existing one with a
# `lookup` of the namespace -- but lookup returns nothing under `helm template`, which
# has no cluster to ask. Rendered and applied, as both this script and install-old.sh do
# it, the chart therefore mints a new project id on every single run and relabels the
# namespace with it, quietly reassigning every workspace in there to a project that
# did not exist a moment ago.
#
# So the lookup is done here, where there is a cluster to ask, and a substitution in
# the aiwb entry puts the answer back into the render. A first install finds no label
# and generates one, which is what the chart would have done.
CF_AIWB_PROJECT_ID="$(kubectl get namespace workbench \
  -o jsonpath="{.metadata.labels['airm\.silogen\.ai/project-id']}" 2>/dev/null || true)"
if [ -z "${CF_AIWB_PROJECT_ID}" ]; then
  CF_AIWB_PROJECT_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  echo "✅ AIWB project id ${CF_AIWB_PROJECT_ID} (new)"
else
  echo "✅ AIWB project id ${CF_AIWB_PROJECT_ID} (kept from namespace workbench)"
fi
export CF_AIWB_PROJECT_ID

# ============================================================================
# OBJECT STORAGE CREDENTIALS
# ============================================================================
# The S3 access keys, with the same names and the same placeholder defaults
# install-old.sh uses, because the two must agree about what they mean.
#
# These are not this step's own configuration. The access keys are written into
# OpenBao's secret definitions here, and the same variables are used later to
# build the SeaweedFS filer's s3.json identities and the minio-credentials Secret
# that AIWB and workbench pods authenticate with. All three have to be rendered
# from the same values or AIWB gets credentials the object store does not know.
#
# That is also why they are read from the environment rather than declared in the
# values file: a run with the variables set must be able to change all three
# together, and a value committed to the values file could not be one of them.
#
# The defaults are placeholders, as install-old.sh's are. Set them for any deployment
# that is not a throwaway:
#
#     MINIO_API_ACCESS_KEY=... MINIO_API_SECRET_KEY=... ./install.sh
#
MINIO_API_ACCESS_KEY="${MINIO_API_ACCESS_KEY:-placeholder}"
MINIO_API_SECRET_KEY="${MINIO_API_SECRET_KEY:-placeholder}"
MINIO_CONSOLE_ACCESS_KEY="${MINIO_CONSOLE_ACCESS_KEY:-placeholder}"
MINIO_CONSOLE_SECRET_KEY="${MINIO_CONSOLE_SECRET_KEY:-placeholder}"
export MINIO_API_ACCESS_KEY MINIO_API_SECRET_KEY
export MINIO_CONSOLE_ACCESS_KEY MINIO_CONSOLE_SECRET_KEY

# Where the external object store is, for PLUGGABLE_S3=true. The redirect Service
# that stands in for the in-cluster store needs an address rather than a name,
# because it is Endpoints written by hand and those hold IPs. Both defaults are
# install-old.sh's and describe a MinIO container on a Rancher Desktop host, so they are
# placeholders in the same sense the keys above are.
MINIO_PORT="${MINIO_PORT:-9999}"
MINIO_HOST_IP="${MINIO_HOST_IP:-192.168.127.254}"
# The same endpoint by name, and the bucket in it, for the consumer that is told where
# the object store is rather than reaching it through the in-cluster name: AIWB is
# pointed straight at it, one indirection closer to the truth than the redirect
# Service.
MINIO_HOST="${MINIO_HOST:-host.docker.internal}"
MINIO_BUCKET="${MINIO_BUCKET:-default-bucket}"
export MINIO_PORT MINIO_HOST_IP MINIO_HOST MINIO_BUCKET

# ============================================================================
# DEPLOYMENT SHAPE: DATABASE AND OBJECT STORE
# ============================================================================
# Whether the cluster brings its own PostgreSQL and object store or is pointed at
# ones that already exist. The apps that only make sense in one shape carry
# skipWhen: PLUGGABLE_DB=true or PLUGGABLE_S3=true and drop out of the order, and
# the credential secrets below are written differently in each shape.
PLUGGABLE_DB="${PLUGGABLE_DB:-false}"
PLUGGABLE_S3="${PLUGGABLE_S3:-false}"
export PLUGGABLE_DB PLUGGABLE_S3

# The credentials AIWB and Keycloak read at startup. Both shapes use the same two
# user/password pairs; what changes is the secret they are written into and whether
# a CNPG cluster is bootstrapped from them.
#
# In-cluster PostgreSQL (PLUGGABLE_DB=false) additionally needs superuser
# credentials, which CNPG generates the cluster's own superuser from.
AIWB_DB_USER="${AIWB_DB_USER:-aiwb_user}"
AIWB_DB_PASSWORD="${AIWB_DB_PASSWORD:-examplepassword}"
KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloak}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-examplepassword}"
AIWB_CNPG_SUPERUSER_USER="${AIWB_CNPG_SUPERUSER_USER:-placeholder}"
AIWB_CNPG_SUPERUSER_PASSWORD="${AIWB_CNPG_SUPERUSER_PASSWORD:-placeholder}"
KEYCLOAK_CNPG_SUPERUSER_USER="${KEYCLOAK_CNPG_SUPERUSER_USER:-placeholder}"
KEYCLOAK_CNPG_SUPERUSER_PASSWORD="${KEYCLOAK_CNPG_SUPERUSER_PASSWORD:-placeholder}"
# Login passwords Keycloak bootstraps: admin console (silogen-admin) and the
# airm-realm dev user (devuser@${DOMAIN}). Written into aiwb-infra Secrets and
# referenced from there; default matches the secrets file's placeholder.
KEYCLOAK_INITIAL_ADMIN_PASSWORD="${KEYCLOAK_INITIAL_ADMIN_PASSWORD:-placeholder}"
KEYCLOAK_INITIAL_DEVUSER_PASSWORD="${KEYCLOAK_INITIAL_DEVUSER_PASSWORD:-placeholder}"
export AIWB_DB_USER AIWB_DB_PASSWORD KEYCLOAK_DB_USER KEYCLOAK_DB_PASSWORD
export AIWB_CNPG_SUPERUSER_USER AIWB_CNPG_SUPERUSER_PASSWORD
export KEYCLOAK_CNPG_SUPERUSER_USER KEYCLOAK_CNPG_SUPERUSER_PASSWORD
export KEYCLOAK_INITIAL_ADMIN_PASSWORD KEYCLOAK_INITIAL_DEVUSER_PASSWORD

# Where that external PostgreSQL is, and what the two databases are called in it.
# Read only by the PLUGGABLE_DB=true steps, which expect the databases and roles to
# exist already. The host default is install-old.sh's and is a Docker Desktop alias, so it
# is a placeholder in the same sense the passwords above are.
POSTGRES_HOST="${POSTGRES_HOST:-host.docker.internal}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
AIWB_DB_NAME="${AIWB_DB_NAME:-aiwb}"
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
export POSTGRES_HOST POSTGRES_PORT AIWB_DB_NAME KEYCLOAK_DB_NAME

# ============================================================================
# ENVOY AI GATEWAY SETTINGS
# ============================================================================
# How many worker threads Envoy starts. Left to itself it starts one per cpuset
# thread and each costs about four file descriptors before serving a request,
# while CRI-O hands containers a soft nofile limit of 1024 — so a node with 256
# or more cores exhausts it during startup and the data plane never comes up.
# Raising the limit instead would mean a node-level MachineConfig for CRI-O, a
# far larger blast radius than bounding a thread count the gateway never needs.
ENVOY_CONCURRENCY="${ENVOY_CONCURRENCY:-4}"

# The seed the AI controller encrypts MCP session state with. Same placeholder
# default as install-old.sh and as values.yaml; override it on any cluster that will
# serve real traffic.
AI_GATEWAY_MCP_SEED="${AI_GATEWAY_MCP_SEED:-cluster-forge-default-seed-override-in-production}"
export ENVOY_CONCURRENCY AI_GATEWAY_MCP_SEED

# The Secret holding the certificate the OpenShift router serves. The AI gateway's
# Route is TLS-passthrough, so HAProxy presents no certificate of its own and
# whatever sits in envoy-gateway-system is what clients actually see; copying the
# router's own wildcard for *.${DOMAIN} covers ${AI_HOST} without asking anyone to
# trust a new CA.
#
# The ingresscontroller names it only when an administrator supplied one, so an
# empty answer means the cluster is serving its own generated certificate under
# the well-known name. Same fallback install-old.sh uses.
CF_ROUTER_CERT="$(kubectl get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)"
CF_ROUTER_CERT="${CF_ROUTER_CERT:-router-certs-default}"
export CF_ROUTER_CERT

# ============================================================================
# APP FIELD LOOKUP
# ============================================================================
# app_field <app> <yaml path> : print a field for an app, or empty when absent.
#
# Reads values-openshift.yaml first and falls back to root/values.yaml only when
# the app is marked root-inherited. That is the whole of the inheritance rule:
# the release states an app's defaults, this file overrides what OpenShift needs
# differently, and an app that root/values.yaml has never heard of (every extra/
# manifest, every custom step) sets root-inherited: false and stands alone.
app_field() {
  local app="$1" path="$2" v
  v=$(yq ".apps.\"${app}\".${path} // \"\"" "${CF_OPENSHIFT_VALUES}")
  if [ -n "${v}" ] && [ "${v}" != "null" ]; then
    printf '%s' "${v}"
    return 0
  fi
  if [ "$(yq ".apps.\"${app}\".root-inherited // false" "${CF_OPENSHIFT_VALUES}")" = "true" ]; then
    v=$(yq ".apps.\"${app}\".${path} // \"\"" "${CF_ROOT_VALUES}")
    [ "${v}" = "null" ] && v=""
    printf '%s' "${v}"
  fi
}

# app_namespace <app> : the app's namespace, with ${VAR} expanded.
#
# Expanded because one namespace here is not a constant: the AMD GPU operator's,
# which is wherever that operator was installed from -- its own namespace when this
# script installs it, openshift-amd-gpu when it came from the OpenShift catalogue.
# See CF_AMD_GPU_NS. Every other entry names a literal and passes through
# unchanged.
app_namespace() {
  local app="$1"
  expand_env_refs "${app}" "$(app_field "${app}" 'namespace')"
}

# ============================================================================
# EXTRA OBJECTS
# ============================================================================
# extraObjects: is a block of YAML applied after the step's own install, for the
# objects install-old.sh creates with an inline heredoc: an OpenShift-only RBAC
# binding, a StorageClass, an alias ConfigMap. They belong to a step but come
# from neither its chart nor a file in extra/.
#
# Kept as data rather than as bash inside a handler for two reasons. An operator
# can apply this verbatim, whereas a heredoc buried in a shell function has to
# be rewritten in Go before it can. And it keeps apps that need one small extra
# object on mode: core, instead of promoting them to custom and losing the
# declarative chart definition along with it.
#
# Applied before verify:, matching install-old.sh, which creates the kyverno RBAC
# binding before waiting on the deployment that needs it.
render_extra_objects() {
  local app="$1" objects
  objects="$(yq ".apps.\"${app}\".extraObjects // \"\"" "${CF_OPENSHIFT_VALUES}")"
  [ -z "${objects}" ] && return 0
  # ${VAR} filled from the environment, the same way a helm parameter's value is.
  # The objects that need it are the credential Secrets install-old.sh assembles with
  # --from-literal: their names and namespaces are as fixed as anything else here,
  # and only the values cannot be committed.
  expand_env_refs "${app}" "${objects}"
}

apply_extra_objects() {
  local app="$1" objects
  objects="$(render_extra_objects "${app}")"
  [ -z "${objects}" ] && return 0
  echo "📦 Applying extra objects declared for ${app}..."
  printf '%s\n' "${objects}" | ssa_apply
}

# configMaps: builds a ConfigMap out of files in the cluster-forge repository, the way
# install-old.sh does with `kubectl create configmap --from-file`.
#
# For a step whose payload includes a program rather than configuration: the
# cluster-auth shim is a hundred lines of Python that a Deployment mounts and runs. The
# file stays where it is and is read from there, so this script and install-old.sh run the
# same shim, and the alternative -- pasting the program into this file's YAML -- keeps
# two copies of it in one repository.
#
# Applied before extraObjects, because what mounts these is usually declared there and
# a Deployment whose ConfigMap does not exist yet sits in ContainerCreating.
apply_config_maps() {
  local app="$1" total i name ns key path file
  local -a from_file_args ns_args
  total="$(yq ".apps.\"${app}\".configMaps | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in ''|null|0) return 0 ;; esac

  for (( i = 0; i < total; i++ )); do
    name="$(yq -N ".apps.\"${app}\".configMaps[${i}].name // \"\"" "${CF_OPENSHIFT_VALUES}")"
    ns="$(expand_env_refs "${app}" \
      "$(yq -N ".apps.\"${app}\".configMaps[${i}].namespace // \"\"" "${CF_OPENSHIFT_VALUES}")")"
    [ -z "${ns}" ] && ns="$(app_namespace "${app}")"
    if [ -z "${name}" ] || [ -z "${ns}" ]; then
      echo "❌ ${app}: configMaps[${i}] needs name: and a namespace" >&2
      exit 1
    fi

    from_file_args=()
    while read -r key; do
      [ -z "${key}" ] && continue
      path="$(yq -N ".apps.\"${app}\".configMaps[${i}].files[] | select(.key == \"${key}\") | .path" \
        "${CF_OPENSHIFT_VALUES}")"
      if [ -z "${path}" ]; then
        echo "❌ ${app}: configMaps[${i}] key ${key} has no path:" >&2
        exit 1
      fi
      file="$(ensure_repo_file "${path}")"
      from_file_args+=(--from-file="${key}=${file}")
    done < <(yq -N ".apps.\"${app}\".configMaps[${i}].files[].key" "${CF_OPENSHIFT_VALUES}")

    if [ "${#from_file_args[@]}" -eq 0 ]; then
      echo "❌ ${app}: configMaps[${i}] declares no files:" >&2
      exit 1
    fi

    echo "📦 Building configmap/${name} in ${ns} from ${#from_file_args[@]} file(s)..."
    ns_args=(--namespace "${ns}")
    kubectl create configmap "${name}" "${ns_args[@]}" "${from_file_args[@]}" \
      --dry-run=client -o yaml | ssa_apply
  done
}

# extraManifests: is the same idea for a file that already exists in extra/,
# rather than YAML written inline. Used where a step has to correct what its own
# chart just installed: the chart is the upstream artifact, the manifest is the
# local amendment, and the two belong to one step because the intermediate state
# — chart applied, amendment not — is the broken one.
#
# A separate step for the amendment would let exactly that state happen, so
# these are deliberately not modelled as their own entries in the install order.
apply_extra_manifests() {
  local app="$1" total name file
  total="$(yq ".apps.\"${app}\".extraManifests | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in ''|null|0) return 0 ;; esac

  while read -r name; do
    [ -z "${name}" ] && continue
    file="${EXTRA_DIR}/${name}"
    ensure_extra_file "${file}"
    echo "📦 Applying ${name}..."
    ssa_apply < "${file}"
  done < <(yq ".apps.\"${app}\".extraManifests[]" "${CF_OPENSHIFT_VALUES}")
}

# ============================================================================
# DELETE BEFORE INSTALL
# ============================================================================
# deleteBefore: is a list of objects to remove before the step installs, for the
# cases where server-side apply cannot get from the object on the cluster to the
# one the step wants.
#
# It exists because SSA merges list entries by their key rather than replacing
# the list, so a field the step moved to a new value can end up alongside the old
# one instead of superseding it. A container port is the example that forced this:
# keyed by port number, so re-applying a DaemonSet on a different port keeps both
# entries and the apply fails on two ports sharing one name.
#
# Each entry names resource, name and an optional namespace, defaulting to the
# app's. Missing objects are not an error: on a first run there is nothing to
# delete.
#
# unless: makes the delete conditional, skipping it when the value at jsonPath:
# already equals: what the step is going to apply. Worth the extra field because
# this runs on every reconcile, and deleting a DaemonSet that is already correct
# would restart a pod on every node each time round for no reason.
apply_delete_before() {
  local app="$1" total i resource name ns json_path expected actual
  local -a ns_args

  total="$(yq ".apps.\"${app}\".deleteBefore | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in ''|null|0) return 0 ;; esac

  for (( i = 0; i < total; i++ )); do
    resource="$(yq ".apps.\"${app}\".deleteBefore[${i}].resource // \"\"" "${CF_OPENSHIFT_VALUES}")"
    name="$(yq ".apps.\"${app}\".deleteBefore[${i}].name // \"\"" "${CF_OPENSHIFT_VALUES}")"
    if [ -z "${resource}" ] || [ -z "${name}" ]; then
      echo "❌ ${app}: deleteBefore[${i}] needs resource: and name:" >&2
      exit 1
    fi

    ns="$(yq ".apps.\"${app}\".deleteBefore[${i}].namespace // \"\"" "${CF_OPENSHIFT_VALUES}")"
    ns="${ns:-$(app_namespace "${app}")}"
    ns_args=()
    [ -n "${ns}" ] && ns_args=(-n "${ns}")

    # Nothing there is the normal case on a first run, and asking first keeps the
    # log honest about whether anything was removed.
    if ! kubectl get "${resource}" "${name}" "${ns_args[@]}" >/dev/null 2>&1; then
      continue
    fi

    json_path="$(yq ".apps.\"${app}\".deleteBefore[${i}].unless.jsonPath // \"\"" "${CF_OPENSHIFT_VALUES}")"
    if [ -n "${json_path}" ]; then
      expected="$(yq ".apps.\"${app}\".deleteBefore[${i}].unless.equals // \"\"" "${CF_OPENSHIFT_VALUES}")"
      # Without equals: the comparison would hold whenever the field is unset,
      # which reads as "already correct" and skips the delete for the wrong reason.
      if [ -z "${expected}" ]; then
        echo "❌ ${app}: deleteBefore[${i}].unless needs equals: alongside jsonPath:" >&2
        exit 1
      fi
      expected="$(expand_env_refs "${app}" "${expected}")"
      actual="$(kubectl get "${resource}" "${name}" "${ns_args[@]}" \
        -o jsonpath="${json_path}" 2>/dev/null || true)"
      if [ "${actual}" = "${expected}" ]; then
        echo "ℹ️  ${app}: keeping ${resource}/${name}, ${json_path} is already ${expected}"
        continue
      fi
      echo "🗑️  Deleting ${resource}/${name}${ns:+ in ${ns}}: ${json_path} is '${actual}', not ${expected}"
    else
      echo "🗑️  Deleting ${resource}/${name}${ns:+ in ${ns}}..."
    fi

    retry kubectl delete "${resource}" "${name}" "${ns_args[@]}" --ignore-not-found \
      --request-timeout="${KUBECTL_REQUEST_TIMEOUT}"
  done
}

# ============================================================================
# PATCHES
# ============================================================================
# patches: is a list of kubectl patch operations, for the objects a step must
# adjust but does not own — an OpenShift platform singleton it did not create,
# or something its own chart installed with a setting that does not suit.
#
# Each entry names resource, name, an optional namespace, the patch body, and
# type: (default merge). stage: pre applies it before the step installs anything,
# stage: post (the default) afterwards. Both exist because both are needed: an
# admission setting has to be in place before the objects it governs arrive,
# while a readiness probe can only be corrected once its Deployment exists.
#
# A patch is the one kind of change nothing else here can express. It is also
# the one most likely to be silently undone, by a platform operator reconciling
# its own resource or by a later chart upgrade, which is why the entries that
# use it pair it with a jsonPath check under verify:.
apply_patches() {
  local app="$1" stage="$2" total i resource name ns type body entry_stage
  local -a ns_args

  total="$(yq ".apps.\"${app}\".patches | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in ''|null|0) return 0 ;; esac

  for (( i = 0; i < total; i++ )); do
    entry_stage="$(yq ".apps.\"${app}\".patches[${i}].stage // \"post\"" "${CF_OPENSHIFT_VALUES}")"
    [ "${entry_stage}" = "${stage}" ] || continue

    resource="$(yq ".apps.\"${app}\".patches[${i}].resource // \"\"" "${CF_OPENSHIFT_VALUES}")"
    name="$(yq ".apps.\"${app}\".patches[${i}].name // \"\"" "${CF_OPENSHIFT_VALUES}")"
    body="$(yq ".apps.\"${app}\".patches[${i}].patch // \"\"" "${CF_OPENSHIFT_VALUES}")"
    if [ -z "${resource}" ] || [ -z "${name}" ] || [ -z "${body}" ]; then
      echo "❌ ${app}: patches[${i}] needs resource:, name: and patch:" >&2
      exit 1
    fi

    type="$(yq ".apps.\"${app}\".patches[${i}].type // \"merge\"" "${CF_OPENSHIFT_VALUES}")"
    ns="$(yq ".apps.\"${app}\".patches[${i}].namespace // \"\"" "${CF_OPENSHIFT_VALUES}")"
    ns_args=()
    [ -n "${ns}" ] && ns_args=(-n "${ns}")

    echo "🔧 Patching ${resource}/${name}${ns:+ in ${ns}}..."
    retry kubectl patch "${resource}" "${name}" "${ns_args[@]}" \
      --type="${type}" -p "${body}"
  done
}

# ============================================================================
# VERIFICATION
# ============================================================================
# An entry's verify: block is a list of read-back checks, run after the step
# regardless of its mode. Needed because success reported by the tools is not
# success on the cluster: `kubectl apply` reports per object it managed to
# parse, `helm template` happily renders a chart whose crds/ it skipped, and a
# Deployment can be applied and never become available. Each of those exits 0.
#
# A check names a resource and selects objects one of three ways:
#
#   name:        one object that must exist
#   names:       several objects, all of which must exist
#   namePrefix:  at least minCount objects whose name starts with it (default 1)
#
# and may additionally require something of them beyond existence:
#
#   condition: Available    with an optional timeout:, default 120s
#   jsonPath: + equals:     the value read at that path must equal that string
#   jsonPath: + notEmpty:   something must have filled it in; waits for timeout:
#   jsonPath: + empty:      nothing must have filled it in
#   jsonPath: + contains:   the value must contain that string
#
# jsonPath is what makes a patch verifiable. Existence proves nothing about an
# object a step did not create but only amended, and the platform operator that
# owns such an object can reconcile the amendment away at any time.
#
# namespace: defaults to the app's own, so cluster-scoped checks omit it.
#
# These live in the values file rather than inside each handler because they
# are the contract, not the implementation: an operator reconciling this file
# turns each check into a status condition, and a check that only existed in
# bash would be invisible to it.
verify_field() {
  local app="$1" i="$2" f="$3" v
  v="$(yq ".apps.\"${app}\".verify[${i}].${f} // \"\"" "${CF_OPENSHIFT_VALUES}")"
  [ "${v}" = "null" ] && v=""
  printf '%s' "${v}"
}

# duration_seconds <kubectl-style duration> : 120s, 2m and a bare 120 all become
# 120. Needed because the jsonPath checks poll in bash rather than handing the
# duration to `kubectl wait`, which parses its own.
duration_seconds() {
  local v="$1"
  case "${v}" in
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *)  echo "${v}" ;;
  esac
}

# verify_jsonpath <resource> <object> <jsonPath> <predicate> <expected> <seconds> [-n ns]
# Re-reads the field until it satisfies the predicate or the budget runs out, and
# prints whatever it last saw so the caller can report it. A budget of 0 makes it
# a single read, which is what an `equals` check without timeout: wants: the value
# it asserts was either just written by the step or has been reconciled away by
# whoever owns the object, and waiting cannot change which.
verify_jsonpath() {
  local resource="$1" obj="$2" json_path="$3" predicate="$4" expected="$5" budget="$6"
  shift 6
  local actual deadline=$(( SECONDS + budget ))
  while :; do
    actual="$(kubectl get "${resource}" "${obj}" "$@" -o jsonpath="${json_path}" 2>/dev/null || true)"
    case "${predicate}" in
      notEmpty) [ -n "${actual}" ] && { printf '%s' "${actual}"; return 0; } ;;
      empty)    [ -z "${actual}" ] && { printf '%s' "${actual}"; return 0; } ;;
      contains) [[ "${actual}" == *"${expected}"* ]] && { printf '%s' "${actual}"; return 0; } ;;
      *)        [ "${actual}" = "${expected}" ] && { printf '%s' "${actual}"; return 0; } ;;
    esac
    if [ "${SECONDS}" -ge "${deadline}" ]; then printf '%s' "${actual}"; return 1; fi
    sleep 5
  done
}

run_verify() {
  local app="$1" total i resource ns ns_shown name prefix selector min cond timeout timeout_set found obj
  local json_path expected predicate budget actual
  local -a targets ns_args matched

  # A step with no checks is not an error — some genuinely have no read-back
  # worth making — but it is worth saying out loud. Left silent, the gap only
  # shows up under an operator, as a step that can never report whether it is
  # satisfied and so must redo its work on every reconcile.
  total="$(yq ".apps.\"${app}\".verify | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in
    ''|null|0)
      echo "⚠️  ${app}: no verify: block — nothing read back, so the result of this step is unchecked" >&2
      return 0
      ;;
  esac

  for (( i = 0; i < total; i++ )); do
    resource="$(verify_field "${app}" "${i}" 'resource')"
    if [ -z "${resource}" ]; then
      echo "❌ ${app}: verify[${i}] has no resource:" >&2
      exit 1
    fi

    # An explicit namespace wins, otherwise the app's own. kubectl ignores -n
    # on cluster-scoped resources, so inheriting one is harmless — but it is
    # only quoted back in errors when the check asked for it, since naming a
    # namespace for a CRD or a StorageClass sends people the wrong way.
    ns="$(expand_env_refs "${app}" "$(verify_field "${app}" "${i}" 'namespace')")"
    ns_shown="${ns}"
    [ -z "${ns}" ] && ns="$(app_namespace "${app}")"
    ns_args=()
    [ -n "${ns}" ] && ns_args=(-n "${ns}")

    cond="$(verify_field "${app}" "${i}" 'condition')"
    timeout_set="$(verify_field "${app}" "${i}" 'timeout')"
    timeout="${timeout_set:-120s}"

    mapfile -t targets < <(yq ".apps.\"${app}\".verify[${i}].names[]" "${CF_OPENSHIFT_VALUES}")
    name="$(verify_field "${app}" "${i}" 'name')"
    [ -n "${name}" ] && targets+=("${name}")
    prefix="$(verify_field "${app}" "${i}" 'namePrefix')"

    # selector: names the objects by label instead, and then everything below reads
    # as though the entry had listed them. For the checks whose subject is the
    # cluster rather than anything this file installed -- which nodes carry a
    # feature label, which of them advertise a GPU -- where the names are the
    # hardware's and knowing them in advance is not possible.
    selector="$(expand_env_refs "${app}" "$(verify_field "${app}" "${i}" 'selector')")"
    if [ -n "${selector}" ]; then
      min="$(verify_field "${app}" "${i}" 'minCount')"
      min="${min:-1}"
      mapfile -t matched < <(kubectl get "${resource}" -l "${selector}" "${ns_args[@]}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)
      if [ "${#matched[@]}" -lt "${min}" ]; then
        echo "❌ ${app}: verify[${i}] expected at least ${min} ${resource} matching ${selector}, found ${#matched[@]}" >&2
        exit 1
      fi
      targets+=("${matched[@]}")
    fi

    json_path="$(verify_field "${app}" "${i}" 'jsonPath')"
    # Four ways to judge the field, in the order they are checked: notEmpty for a
    # value that cannot be predicted, empty for a field that has to stay unset,
    # contains for one field of a rendered blob, equals for the rest.
    expected="$(verify_field "${app}" "${i}" 'equals')"
    predicate=equals
    if [ "$(verify_field "${app}" "${i}" 'notEmpty')" = "true" ]; then
      predicate=notEmpty
    elif [ "$(verify_field "${app}" "${i}" 'empty')" = "true" ]; then
      # Not the same as leaving the check off: what it asserts is that whoever owns
      # the object has not filled the field in -- a Service that acquired a selector,
      # a spec field a platform operator defaults when it takes something over.
      predicate=empty
    elif [ -n "$(verify_field "${app}" "${i}" 'contains')" ]; then
      predicate=contains
      expected="$(verify_field "${app}" "${i}" 'contains')"
    fi
    # Expanded the same way a helm parameter's value is, so a check can assert
    # the cluster's own domain or an access key that only the environment knows.
    [ -n "${expected}" ] && expected="$(expand_env_refs "${app}" "${expected}")"

    # notEmpty is inherently a wait: the field it asks about is one a controller
    # fills in after the object appears, so it polls for timeout: like the
    # condition checks do. The other two poll only when the entry asks for it.
    if [ "${predicate}" = notEmpty ] || [ -n "${timeout_set}" ]; then
      budget="$(duration_seconds "${timeout}")"
    else
      budget=0
    fi

    if [ "${#targets[@]}" -gt 0 ]; then
      for obj in "${targets[@]}"; do
        if [ -n "${cond}" ]; then
          kwait --for=condition="${cond}" --timeout="${timeout}" "${resource}/${obj}" "${ns_args[@]}"
        elif [ -n "${json_path}" ]; then
          if ! actual="$(verify_jsonpath "${resource}" "${obj}" "${json_path}" \
              "${predicate}" "${expected}" "${budget}" "${ns_args[@]}")"; then
            case "${predicate}" in
              notEmpty)
                echo "❌ ${app}: verify[${i}] ${resource}/${obj} ${json_path} still empty after ${timeout}" >&2
                ;;
              empty)
                echo "❌ ${app}: verify[${i}] ${resource}/${obj} ${json_path} is set to '${actual}', expected it unset" >&2
                ;;
              contains)
                # The value is printed in full deliberately: these are rendered
                # blobs, and which value went in wrong is the whole question.
                echo "❌ ${app}: verify[${i}] ${resource}/${obj} ${json_path} does not contain '${expected}'" >&2
                echo "   value: ${actual}" >&2
                ;;
              *)
                echo "❌ ${app}: verify[${i}] ${resource}/${obj} ${json_path} is '${actual}', expected '${expected}'" >&2
                ;;
            esac
            exit 1
          fi
        elif ! kubectl get "${resource}" "${obj}" "${ns_args[@]}" >/dev/null 2>&1; then
          echo "❌ ${app}: verify[${i}] expected ${resource}/${obj}${ns_shown:+ in ${ns_shown}} to exist" >&2
          exit 1
        fi
      done
      echo "✅ verify: ${resource} ${targets[*]}${cond:+ is ${cond}}${json_path:+ ${json_path} ${predicate}${expected:+ ${expected}}}"
    elif [ -n "${prefix}" ] || [ -n "$(verify_field "${app}" "${i}" 'minCount')" ]; then
      min="$(verify_field "${app}" "${i}" 'minCount')"
      min="${min:-1}"
      # An empty prefix matches every object of the kind, which is the check for a
      # step whose result carries a name it did not choose: the AMD GPU operator's
      # DeviceConfig is called whatever the person or catalogue that created it
      # decided, and what this step needs to know is that one exists. minCount: on
      # its own asks for that; it is required rather than defaulted so that an entry
      # which simply forgot to name anything still fails.
      mapfile -t matched < <(kubectl get "${resource}" "${ns_args[@]}" -o name 2>/dev/null \
        | grep "/${prefix}" || true)
      found="${#matched[@]}"
      if [ "${found}" -lt "${min}" ]; then
        echo "❌ ${app}: verify[${i}] expected at least ${min} ${resource}/${prefix}*, found ${found}" >&2
        exit 1
      fi
      # A prefix check can ask for a condition too, for the objects whose names are
      # generated: an operator that names a workload after the resource that
      # produced it plus a hash cannot be waited for by name.
      if [ -n "${cond}" ]; then
        for obj in "${matched[@]}"; do
          kwait --for=condition="${cond}" --timeout="${timeout}" "${obj}" "${ns_args[@]}"
        done
      fi
      echo "✅ verify: ${found} ${resource}${prefix:+/${prefix}*}${ns_shown:+ in ${ns_shown}} present${cond:+ and ${cond}}"
    else
      echo "❌ ${app}: verify[${i}] needs one of name:, names: or namePrefix:" >&2
      exit 1
    fi
  done
}

# ============================================================================
# STEP HANDLERS BY MODE
# ============================================================================

# mode: extra — apply one manifest from extra/.
#
# These are the OpenShift-only objects that no chart provides: the custom SCCs,
# the OpenShift Kyverno policies, the NodeFeatureRule fallback and the Routes.
# Applied before any workload where ordering matters, because an SCC that
# arrives late does not retroactively admit a pod — the Deployment has already
# failed at admission and sits at ReplicaFailure/FailedCreate.
# stage_extra_file <app> : print the path of the manifest this step applies, DOMAIN
# already substituted into a copy when the entry asks for it.
#
# Split out of install_extra so uninstall-all.sh reads the same file through the
# same placeholder handling: a Route deleted by name has to be the name the substituted
# manifest created, not the placeholder text.
stage_extra_file() {
  local app="$1" file path out
  path="$(app_field "${app}" 'path')"
  if [ -z "${path}" ]; then
    echo "❌ ${app}: mode extra requires path: (a filename under extra/)" >&2
    exit 1
  fi
  file="${EXTRA_DIR}/${path}"
  ensure_extra_file "${file}"

  # substituteDomain: the manifest carries the cluster's apps domain as a placeholder,
  # in either of the two spellings the extra/ files use — <DOMAIN> in the Kyverno
  # policies, ${DOMAIN} in the Routes. Substituted here rather than committed, because
  # the value is a property of the target cluster.
  if [ "$(app_field "${app}" 'substituteDomain')" = "true" ]; then
    if ! grep -q -e '<DOMAIN>' -e '${DOMAIN}' "${file}"; then
      echo "⚠️  ${app}: substituteDomain is set but ${path} contains no DOMAIN placeholder" >&2
    fi
    out="${CF_WORK_DIR}/${app}.extra.yaml"
    sed -e "s|<DOMAIN>|${DOMAIN}|g" -e "s|\${DOMAIN}|${DOMAIN}|g" "${file}" > "${out}"
    printf '%s' "${out}"
    return 0
  fi
  printf '%s' "${file}"
}

install_extra() {
  local app="$1" file path ns
  local -a ns_args
  path="$(app_field "${app}" 'path')"
  file="$(stage_extra_file "${app}")"

  # namespace: is optional here, and most entries leave it out because their
  # objects are cluster-scoped — SCCs, ClusterRoles, ClusterPolicies — or state
  # their own namespace, as the Routes do. It exists for the remaining case: a
  # namespaced object that names no namespace, which otherwise lands wherever
  # the caller's kubeconfig context happens to point rather than where the
  # manifest intended.
  #
  # Set it only for a file whose objects declare none. kubectl treats
  # --namespace as the default for objects without one, but rejects the apply
  # outright when an object names a different namespace, so pointing it at a
  # file like 09-routes.yaml fails every document in it.
  ns="$(app_namespace "${app}")"
  ns_args=()
  if [ -n "${ns}" ]; then
    ns_args=(--namespace "${ns}")
    if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
      echo "📦 Creating namespace ${ns}..."
      retry kubectl create namespace "${ns}"
    fi
  fi

  # Piped through server-side apply when substituting, which is what install-old.sh
  # does for exactly these files; the ones applied verbatim keep the plain
  # client-side apply it uses for those.
  if [ "$(app_field "${app}" 'substituteDomain')" = "true" ]; then
    echo "📦 Applying ${path} with DOMAIN=${DOMAIN}${ns:+ into namespace ${ns}}..."
    ssa_apply "${ns_args[@]}" < "${file}"
    echo "✅ ${app} applied"
    return 0
  fi

  echo "📦 Applying ${path}${ns:+ into namespace ${ns}}..."
  retry kubectl apply --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f "${file}" "${ns_args[@]}"
  echo "✅ ${app} applied"
}

# helm_parameters <app> : print the app's helmParameters as name=value lines.
#
# Same shape root/values.yaml uses for ArgoCD — a list of {name, value} — so an
# app that already states its parameters there needs nothing restated here. A
# list in values-openshift.yaml replaces that one outright rather than merging
# into it: a partial override of an ordered list has no obvious meaning, and
# guessing at one would be the sort of surprise that is found months later.
# A helm.sh/hook value naming an install event, in either spelling and anywhere in
# the comma-separated list helm accepts. One pattern, used both to list the objects
# that go and to strip them, so the two cannot come to disagree.
HELM_INSTALL_HOOK_PATTERN='(^|,) *(pre|post)-install *(,|$)'
# The default stands in for an object with no hook annotation at all, which is an
# ordinary object and always kept. Spelling it as an install hook lets the one test
# decide both cases, without an `and` -- and yq binds `and` looser than `|`, so a
# two-part condition here reads as a test against the whole document instead.
HELM_HOOK_MATCH="(.metadata.annotations[\"helm.sh/hook\"] // \"pre-install\") \
  | test(\"${HELM_INSTALL_HOOK_PATTERN}\")"

# drop_hooks <app> <rendered file> : remove the hook objects a template-and-apply
# pipeline can never run at the right moment, in place.
#
# `helm template` emits hook objects along with everything else, and applying the
# render creates them for real, immediately, as ordinary objects. That is harmless
# for an install hook -- installing is what this script does -- so those are kept:
# a chart whose pre-install Job does real work still needs it.
#
# Every other event is a lie here. There is no `helm test`, no `helm upgrade` and
# no `helm delete` in this pipeline, so a hook waiting on one of those has no
# trigger, and applying it means running it now instead. What that costs depends on
# what the hook does:
#
#   - test: the opentelemetry-operator chart's three busybox pods, which run once
#     and then sit Completed in the namespace forever. Untidy.
#   - post-upgrade: kyverno's kyverno-migrate-resources Job, which has been sitting
#     in the kyverno namespace for eleven days having never run to completion.
#   - post-delete/pre-delete: the amd-gpu-operator chart's
#     delete-custom-resource-definitions Job, which deletes every NFD and KMM CRD.
#     Applied at install time it destroys the API the operator was just given,
#     which is why install-old.sh renders that chart with --no-hooks.
#
# --no-hooks per chart would be the narrow fix. This is the same thing stated once,
# for every chart, and by what the hook is rather than by which chart shipped it.
#
# Rewritten only when the render mentions hooks at all, so that every other chart
# is applied exactly as helm produced it rather than round-tripped through yq.
drop_hooks() {
  local app="$1" file="$2" obj
  local -a objects
  grep -q 'helm.sh/hook' "${file}" || return 0

  mapfile -t objects < <(yq -N "select(${HELM_HOOK_MATCH} | not) \
    | [.kind + \"/\" + .metadata.name, .metadata.annotations[\"helm.sh/hook\"]] | join(\" \")" "${file}")
  for obj in "${objects[@]}"; do
    [ -z "${obj}" ] && continue
    echo "ℹ️  ${app}: not applying ${obj% *}, a ${obj##* } hook"
  done

  yq "select(${HELM_HOOK_MATCH})" "${file}" > "${file}.kept"
  mv "${file}.kept" "${file}"
}

# filter_render_kinds <app> <rendered file> : keep only onlyKinds:, or drop
# excludeKinds:, from a render, in place.
#
# For the charts that have to be installed in two goes because one part of them
# cannot be admitted until another part is running. KServe is the case that forced
# it: its ClusterServingRuntimes are validated by a webhook its own controller
# serves, so re-applying the chart while that webhook has no endpoints fails on
# exactly those objects. install-old.sh handles it by applying the whole chart three
# times and swallowing the errors of the first two.
#
# Two entries with these two fields say the same thing without the retries: one
# installs everything except that kind, its verify: block proves the webhook is
# answering, and the next installs the kind. The split is by kind rather than by
# template name deliberately -- a chart that grows a template still gets it
# applied, by whichever of the two entries covers its kind.
filter_render_kinds() {
  local app="$1" file="$2" only exclude filter kind
  local -a only_kinds exclude_kinds
  # No `// ""` fallback: it turns an absent key into one empty entry, and then
  # every app looks as though it set both fields.
  mapfile -t only_kinds < <(yq -N ".apps.\"${app}\".onlyKinds[]?" "${CF_OPENSHIFT_VALUES}")
  mapfile -t exclude_kinds < <(yq -N ".apps.\"${app}\".excludeKinds[]?" "${CF_OPENSHIFT_VALUES}")

  if [ "${#only_kinds[@]}" -gt 0 ] && [ "${#exclude_kinds[@]}" -gt 0 ]; then
    echo "❌ ${app}: onlyKinds: and excludeKinds: are alternatives, not both" >&2
    exit 1
  fi
  if [ "${#only_kinds[@]}" -eq 0 ] && [ "${#exclude_kinds[@]}" -eq 0 ]; then
    return 0
  fi

  # An or/and chain of plain comparisons rather than a set membership test: yq
  # rebinds . to the left of a pipe, so the array forms of this read as though the
  # document were the array.
  if [ "${#only_kinds[@]}" -gt 0 ]; then
    for kind in "${only_kinds[@]}"; do
      filter="${filter:+${filter} or }.kind == \"${kind}\""
    done
    only="$(printf '%s, ' "${only_kinds[@]}")"
    echo "ℹ️  ${app}: applying only these kinds: ${only%, }"
  else
    for kind in "${exclude_kinds[@]}"; do
      filter="${filter:+${filter} and }.kind != \"${kind}\""
    done
    exclude="$(printf '%s, ' "${exclude_kinds[@]}")"
    echo "ℹ️  ${app}: not applying these kinds: ${exclude%, }"
  fi

  # No -N: that suppresses the document separators and would fuse the whole render
  # into one unparseable document.
  yq "select(${filter})" "${file}" > "${file}.kept"
  if [ ! -s "${file}.kept" ]; then
    echo "❌ ${app}: the kind filter left nothing to apply — check onlyKinds/excludeKinds against the chart" >&2
    exit 1
  fi
  mv "${file}.kept" "${file}"
}

# fill_render_namespace <app> <file> <namespace> : give every namespaced object in
# a render that states no namespace the release namespace, which is what
# `helm install` would have done with it.
#
# `helm template` does not do this itself. It substitutes .Release.Namespace
# wherever a template asks for it and leaves the rest alone, so a chart whose
# ServiceAccount or Role omits metadata.namespace renders without one — and
# `kubectl apply` then puts it in whatever namespace the caller's kubeconfig
# context happens to name. Nothing fails: the object is created, in the wrong
# place, and the workload that needed it goes without.
#
# install-old.sh works around this by switching the context around the apply, which is
# also how it came to leave a second copy of kserve's ServiceAccount, Role and
# RoleBinding in `default`: it resets the context before its third apply.
#
# Passing --namespace to kubectl instead would be simpler but wrong here: kubectl
# rejects the whole apply when any object names a different namespace, and several
# charts render into more than one.
fill_render_namespace() {
  local app="$1" file="$2" ns="$3" kind namespaced_kinds
  local -a render_kinds

  # The API server is the only authority on which kinds take a namespace, and CRDs
  # installed by earlier steps mean the answer changes during a run. KIND is the
  # last column of the default output.
  namespaced_kinds="$(kubectl api-resources --namespaced=true --no-headers 2>/dev/null \
    | awk '{print $NF}' | sort -u)"
  if [ -z "${namespaced_kinds}" ]; then
    echo "⚠️  ${app}: could not list namespaced kinds, leaving the render's namespaces alone" >&2
    return 0
  fi

  mapfile -t render_kinds < <(yq -N '.kind // ""' "${file}" | sort -u | grep -v '^$')
  for kind in "${render_kinds[@]}"; do
    grep -qx "${kind}" <<<"${namespaced_kinds}" || continue
    # with(select(...); ...) rather than a bare select, because an assignment
    # through a select drops the documents the select filtered out.
    yq -i "with(select(.kind == \"${kind}\");
                .metadata.namespace = (.metadata.namespace // \"${ns}\"))" "${file}"
  done
}

# build_sed_args <app> : fill SED_ARGS with the app's substitutions as sed -e
# expressions, or empty it when the app declares none.
#
# Sets a global rather than printing, because it runs in the caller's shell: a
# substitution referring to an unset variable has to be able to stop the run, and
# an exit inside `<(...)` only kills the subshell and leaves the caller going with
# half a list.
#
# For the text edits install-old.sh makes to a manifest on its way to the cluster.
# The one it needs repeatedly is rewriting external-secrets.io/v1beta1 to v1,
# because every ExternalSecret and SecretStore in this repo is written against a
# version the pinned operator no longer serves; it does the same sed in three
# separate places.
#
# from: is a sed basic regular expression and to: its replacement, which is what
# install-old.sh's own seds are, so the ones that need anchors and a backreference
# carry over unchanged. Nothing here understands YAML: these are for API versions,
# namespaces and hostnames, and a manifest that needs restructuring wants fixing
# upstream instead of a cleverer field here.
SED_ARGS=()
build_sed_args() {
  local app="$1" total i from to
  SED_ARGS=()
  total="$(yq ".apps.\"${app}\".substitutions | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in ''|null|0) return 0 ;; esac
  for (( i = 0; i < total; i++ )); do
    from="$(yq ".apps.\"${app}\".substitutions[${i}].from // \"\"" "${CF_OPENSHIFT_VALUES}")"
    to="$(yq ".apps.\"${app}\".substitutions[${i}].to // \"\"" "${CF_OPENSHIFT_VALUES}")"
    if [ -z "${from}" ]; then
      echo "❌ ${app}: substitutions[${i}] needs from:" >&2
      exit 1
    fi
    # ${VAR} on either side, so a replacement can carry a value only the cluster
    # knows -- the namespace the GPU operator turned out to be in, for instance.
    from="$(expand_env_refs "${app}" "${from}")"
    to="$(expand_env_refs "${app}" "${to}")"
    # | as the delimiter, since these values are API groups and URLs full of /.
    SED_ARGS+=(-e "s|${from}|${to}|g")
  done
}

# bust_discovery_cache <app> <file or directory> : drop kubectl's cached view of
# the API when what was just applied adds to it.
#
# kubectl caches the server's resource list under ~/.kube/cache/discovery and
# does not ask again for ten minutes. A step that installs a CRD and a later step
# that applies one of those custom resources inside that window fails with "no
# matches for kind", which reads as a CRD that never installed rather than as a
# stale cache. install-old.sh clears it after the external-secrets CRDs for exactly
# this reason; here it happens for any step that brings CRDs with it.
bust_discovery_cache() {
  local app="$1" source="$2" cache
  grep -rq 'kind: CustomResourceDefinition' "${source}" || return 0
  cache="${KUBECACHEDIR:-${HOME}/.kube/cache}/discovery"
  [ -d "${cache}" ] || return 0
  echo "ℹ️  ${app}: installed CRDs, clearing kubectl's discovery cache"
  rm -rf "${cache}"
}

# write_values_object <app> <values file> <destination> : extract the app's
# valuesObject block into a file helm can read with --values. Returns non-zero
# when the app declares none, so the caller can leave the flag off entirely
# rather than pass helm an empty file.
write_values_object() {
  local app="$1" src="$2" out="$3"
  [ "$(yq ".apps.\"${app}\" | has(\"valuesObject\")" "${src}")" = "true" ] || return 1
  yq ".apps.\"${app}\".valuesObject" "${src}" > "${out}"
}

# expand_env_refs <app> <string> : replace every ${VAR} with that environment
# variable's value.
#
# An unset or empty variable is fatal rather than expanded to nothing: the values
# that use this are domains and access keys, and a chart handed an empty one
# renders an install that comes up and is quietly wrong -- a route on no host, a
# secret store with no key.
expand_env_refs() {
  local app="$1" s="$2" var rounds=0
  while [[ "${s}" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    var="${BASH_REMATCH[1]}"
    if [ -z "${!var:-}" ]; then
      echo "❌ ${app}: '${s}' refers to \${${var}}, which is unset or empty" >&2
      exit 1
    fi
    s="${s//\$\{${var}\}/${!var}}"
    # A value that itself contains ${VAR} would otherwise loop here forever.
    if (( ++rounds > 10 )); then
      echo "❌ ${app}: gave up expanding '${s}' after ${rounds} rounds" >&2
      exit 1
    fi
  done
  printf '%s' "${s}"
}

helm_parameters() {
  local app="$1" file n i when when_var when_val
  file="${CF_OPENSHIFT_VALUES}"
  n="$(yq ".apps.\"${app}\".helmParameters | length" "${file}")"
  if [ "${n}" = "0" ] &&
     [ "$(yq ".apps.\"${app}\".root-inherited // false" "${CF_OPENSHIFT_VALUES}")" = "true" ]; then
    file="${CF_ROOT_VALUES}"
    n="$(yq ".apps.\"${app}\".helmParameters | length" "${file}")"
  fi
  case "${n}" in ''|null|0) return 0 ;; esac

  for (( i = 0; i < n; i++ )); do
    # when: VAR=value — pass this parameter only in that deployment shape. install-old.sh
    # builds the same thing by hand, collecting a shell variable of --set flags behind
    # an if and splicing it into the render: the external database's host and the
    # external object store's URL are parameters that exist in one shape and are
    # meaningless in the other.
    #
    # The inverse sense of skipWhen: on purpose. skipWhen: answers "is this step part
    # of this deployment at all", which is a statement about the whole app and reads
    # better as an exclusion; when: answers "does this input apply", where listing the
    # shape it belongs to is the shorter half.
    #
    # A step whose *contract* differs between shapes -- a different set of verify
    # checks, not just different inputs -- is two entries with skipWhen: instead.
    # Conditioning the parameters of one entry only works while both shapes end in the
    # same state to read back.
    #
    # when: VAR with no =value passes the parameter whenever that variable is set to
    # something, which is how an optional override reads: unset means the chart's own
    # default stands, and there is no value the script could compare against that would
    # not be a second copy of that default drifting here.
    when="$(yq -N ".apps.\"${app}\".helmParameters[${i}].when // \"\"" "${file}")"
    if [ -n "${when}" ]; then
      case "${when}" in
        *=*)
          when_var="${when%%=*}"
          when_val="${when#*=}"
          [ "${!when_var:-}" = "${when_val}" ] || continue ;;
        *)
          [ -n "${!when:-}" ] || continue ;;
      esac
    fi
    yq ".apps.\"${app}\".helmParameters[${i}] | .name + \"=\" + (.value | tostring)" "${file}"
  done
}

# ============================================================================
# RENDERING
# ============================================================================
# The chart path and namespace come from root/values.yaml, the same two fields ArgoCD
# reads, so the two install paths cannot drift apart on where an app goes.

# resolve_chart_dir <app> : set CF_CHART_DIR to the directory holding the app's chart and
# CF_CHART_PATH to what to call it in the log.
#
# Split out of install_core because uninstall-all.sh has to find the same chart to
# render the same objects, and a second copy of this lookup would be a second place for
# path: to mean something slightly different.
#
# Through globals rather than stdout because the callers need two values, and a function
# whose result is read in "$(...)" runs in a subshell that cannot set the second one.
CF_CHART_DIR=""
CF_CHART_PATH=""
resolve_chart_dir() {
  local app="$1"
  CF_CHART_PATH="$(app_field "${app}" 'path')"
  if [ -z "${CF_CHART_PATH}" ]; then
    echo "❌ ${app}: mode core requires path: (a chart directory under sources/)" >&2
    exit 1
  fi
  CF_CHART_DIR="${SOURCES_DIR}/${CF_CHART_PATH}"
  if [ ! -d "${CF_CHART_DIR}" ]; then
    echo "❌ ${app}: no chart at ${CF_CHART_DIR}" >&2
    echo "   path: is resolved under the ${CLUSTER_FORGE_VERSION} tarball's sources/." >&2
    exit 1
  fi
}

# stage_manifest_dir <app> <source dir> : the directory of plain YAML to apply, which is
# the source directory itself unless substitutions: mean a copy has to be edited first.
#
# With substitutions the directory is copied and edited, and the copy is what gets
# applied. The tarball is left untouched, so a re-run starts from the same manifests
# rather than from the last run's output.
stage_manifest_dir() {
  local app="$1" src="$2" out
  build_sed_args "${app}"
  if [ "${#SED_ARGS[@]}" -eq 0 ]; then
    printf '%s' "${src}"
    return 0
  fi
  out="${CF_WORK_DIR}/${app}.manifests"
  rm -rf "${out}"
  mkdir -p "${out}"
  cp -R "${src}/." "${out}/"
  find "${out}" -type f -exec sed -i "${SED_ARGS[@]}" {} +
  echo "ℹ️  ${app}: applied $(( ${#SED_ARGS[@]} / 2 )) substitution(s) to the manifests first" >&2
  printf '%s' "${out}"
}

# render_chart <app> <chart dir> <chart path> <output file> : run the app's chart through
# `helm template` with every input the entry declares, and post-process the result the
# way this script applies it -- hooks dropped, kinds filtered, namespace filled in,
# substitutions made.
#
# Separate from install_core so that what gets applied and what gets deleted are produced
# by one function. uninstall-all.sh renders each step exactly as it was installed and
# deletes what comes out, which only holds while there is a single renderer: values change
# which objects a chart emits and what they are called, so a second implementation that
# drifted in its inputs would delete a different set of objects than the install created.
render_chart() {
  local app="$1" chart_dir="$2" chart_path="$3" rendered="$4"
  local release ns include_crds values_file parameter template
  local values_object_root values_object_local
  local -a helm_args parameters

  release="$(app_field "${app}" 'release')"
  release="${release:-${app}}"
  ns="$(app_namespace "${app}")"
  include_crds="$(app_field "${app}" 'includeCrds')"
  values_file="$(app_field "${app}" 'valuesFile')"

  # helm needs one, and every chart here has one to give. Not checked for the
  # plain-YAML directories that never reach this function: the only one so far is
  # cluster-scoped CRDs that belong to no namespace.
  if [ -z "${ns}" ]; then
    echo "❌ ${app}: mode core requires namespace:" >&2
    exit 1
  fi

  helm_args=(template "${release}" "${chart_dir}" --namespace "${ns}")

  # `helm template` skips a chart's crds/ directory, which only `helm install`
  # reads implicitly, so charts that keep their CRDs there need this asked for
  # explicitly. Off unless the entry says otherwise: several charts here ship
  # crds/ but have those CRDs installed by a separate step, and rendering them
  # twice at different versions is its own problem.
  if [ "${include_crds}" = "true" ]; then
    helm_args+=(--include-crds)
  fi

  # templates: renders only the named templates, helm's --show-only. For a chart
  # written for another platform where only part of it applies here: the rest may
  # target a load balancer this cluster does not have, or a service on a port
  # nothing listens on, and installing it would not fail so much as sit there
  # being wrong.
  #
  # Each name is checked against the chart first. helm errors on a --show-only
  # that matches nothing, but only after rendering, and the message names the
  # pattern rather than the entry that asked for it.
  while read -r template; do
    [ -z "${template}" ] && continue
    if [ ! -f "${chart_dir}/${template}" ]; then
      echo "❌ ${app}: templates: names ${template}, which is not in ${chart_path}" >&2
      exit 1
    fi
    helm_args+=(--show-only "${template}")
  done < <(yq ".apps.\"${app}\".templates[]? // \"\"" "${CF_OPENSHIFT_VALUES}")

  if [ -n "${values_file}" ]; then
    # ArgoCD resolves valuesFile relative to the chart directory, helm relative
    # to the working directory, so it is made absolute against the chart here.
    case "${values_file}" in
      ../*)
        echo "❌ ${app}: valuesFile '${values_file}' points outside the chart, which mode core does not support yet" >&2
        exit 1
        ;;
    esac
    if [ ! -f "${chart_dir}/${values_file}" ]; then
      echo "❌ ${app}: valuesFile not found at ${chart_dir}/${values_file}" >&2
      exit 1
    fi
    helm_args+=(--values "${chart_dir}/${values_file}")
  fi

  # valuesObject: the chart configuration ArgoCD passes inline. Written out and
  # given to helm as a --values file rather than flattened into --set, which has
  # its own escaping rules for the dots and commas that appear in these keys and
  # values, and would turn a nested block into a line noone can read.
  #
  # Order is helm's precedence order and matches ArgoCD's: valuesFile above
  # first, then the root block, then the local one, so an OpenShift override
  # deep-merges into the shared configuration rather than replacing all of it.
  # --set wins over all three regardless of where it appears.
  values_object_root="${CF_WORK_DIR}/${app}.values-root.yaml"
  values_object_local="${CF_WORK_DIR}/${app}.values-openshift.yaml"
  if [ "$(yq ".apps.\"${app}\".root-inherited // false" "${CF_OPENSHIFT_VALUES}")" = "true" ] &&
     write_values_object "${app}" "${CF_ROOT_VALUES}" "${values_object_root}"; then
    helm_args+=(--values "${values_object_root}")
  fi
  if write_values_object "${app}" "${CF_OPENSHIFT_VALUES}" "${values_object_local}"; then
    helm_args+=(--values "${values_object_local}")
  fi

  mapfile -t parameters < <(helm_parameters "${app}")
  for parameter in "${parameters[@]}"; do
    # ${VAR} in a parameter value is filled from the environment. The values that
    # need this are the ones that cannot be committed: the cluster's own domain,
    # discovered at the top of this run, and the object storage access keys that
    # three separate steps have to agree on.
    parameter="$(expand_env_refs "${app}" "${parameter}")"
    # ArgoCD renders these through its own templating, so several in
    # root/values.yaml are Go templates such as {{ .Values.global.domain }}.
    # Passing one to helm verbatim sets the parameter to the literal template
    # text, which usually produces a working install of something misconfigured.
    case "${parameter}" in
      *'{{'*)
        echo "❌ ${app}: helmParameter '${parameter}' is a Go template, which mode core does not resolve yet" >&2
        exit 1
        ;;
    esac
    helm_args+=(--set "${parameter}")
  done

  helm "${helm_args[@]}" > "${rendered}"
  drop_hooks "${app}" "${rendered}"
  filter_render_kinds "${app}" "${rendered}"
  fill_render_namespace "${app}" "${rendered}" "${ns}"
  build_sed_args "${app}"
  if [ "${#SED_ARGS[@]}" -gt 0 ]; then
    sed -i "${SED_ARGS[@]}" "${rendered}"
    echo "ℹ️  ${app}: applied $(( ${#SED_ARGS[@]} / 2 )) substitution(s) to the render" >&2
  fi
}

# mode: core — render a chart out of the release tarball's sources/ and apply it.
#
# The plain case: everything the chart needs already shipped in the tarball, so the step
# is one `helm template` piped through server-side apply. A chart directory and a name for
# it may be passed in, and then the entry's path: is not read at all. That is how mode
# external works: it fetches a chart from a registry and hands the unpacked copy here, so
# a remote chart gets the same treatment as a local one rather than a second renderer that
# would drift from this one.
install_core() {
  local app="$1" chart_dir="${2:-}" chart_path="${3:-}"
  local ns render unsupported rendered apply_dir
  local -a ns_args recurse_args

  if [ -z "${chart_dir}" ]; then
    resolve_chart_dir "${app}"
    chart_dir="${CF_CHART_DIR}"
    chart_path="${CF_CHART_PATH}"
  fi
  ns="$(app_namespace "${app}")"

  # ArgoCD syncs these with CreateNamespace=true; `helm template` renders the
  # namespace into the manifests but does not create it.
  if [ -n "${ns}" ] && ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    echo "📦 Creating namespace ${ns}..."
    retry kubectl create namespace "${ns}"
  fi

  # Not everything under sources/ is a chart. Some entries are a directory of
  # plain YAML, which helm cannot read at all, so they are applied directly.
  render="$(app_field "${app}" 'render')"
  if [ "${render}" = "manifests" ]; then
    for unsupported in valuesFile includeCrds release templates; do
      if [ -n "$(app_field "${app}" "${unsupported}")" ]; then
        echo "❌ ${app}: ${unsupported}: is meaningless with render: manifests" >&2
        exit 1
      fi
    done
    ns_args=()
    [ -n "${ns}" ] && ns_args=(--namespace "${ns}")
    # Non-recursive by default, as kubectl is: a directory holding a chart's
    # rendered output next to a subdirectory of something else should not have
    # the second one applied by accident. recursive: true is for the directories
    # that are deliberately a tree.
    recurse_args=()
    [ "$(app_field "${app}" 'recursive')" = "true" ] && recurse_args=(--recursive)

    apply_dir="$(stage_manifest_dir "${app}" "${chart_dir}")"
    echo "📦 Applying manifests from ${chart_path}${ns:+ into namespace ${ns}}..."
    retry kubectl apply --server-side --force-conflicts \
      --field-manager="${CF_FIELD_MANAGER}" \
      --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f "${apply_dir}" \
      "${recurse_args[@]}" "${ns_args[@]}"
    bust_discovery_cache "${app}" "${apply_dir}"
    echo "✅ ${app} applied"
    return 0
  fi

  rendered="${CF_WORK_DIR}/${app}.rendered.yaml"
  echo "📦 Rendering ${chart_path} into namespace ${ns}..."
  render_chart "${app}" "${chart_dir}" "${chart_path}" "${rendered}"
  ssa_apply < "${rendered}"
  bust_discovery_cache "${app}" "${rendered}"
  echo "✅ ${app} applied"
}

# resolve_values_template <app> <string> : resolve a whole-string {{ .Values.x.y }}
# against root/values.yaml.
#
# ArgoCD templates root/values.yaml through itself before handing it to helm, so
# several fields there hold a reference rather than a value -- repoURL: is
# "{{ .Values.ociRegistry.dockerHub }}", the registry named once at the top of the
# file and used by every external app. Passing that to helm verbatim would ask a
# registry called {{ for a chart.
#
# Only a reference that is the entire value is resolved. A field mixing template with
# text is refused rather than half-handled, because doing that properly means
# implementing Go templating in bash, and the answer to needing that is to write the
# value out in values-openshift.yaml instead.
resolve_values_template() {
  local app="$1" s="$2" path v
  case "${s}" in
    *'{{'*) ;;
    *) printf '%s' "${s}"; return 0 ;;
  esac

  path="$(printf '%s' "${s}" | sed -n 's|^{{ *\.Values\.\([A-Za-z0-9_.-]*\) *}}$|\1|p')"
  if [ -z "${path}" ]; then
    echo "❌ ${app}: '${s}' is a Go template this script cannot resolve" >&2
    echo "   Only a whole value of the form {{ .Values.some.path }} is understood." >&2
    exit 1
  fi

  v="$(yq ".${path} // \"\"" "${CF_ROOT_VALUES}")"
  if [ -z "${v}" ] || [ "${v}" = "null" ]; then
    echo "❌ ${app}: '${s}' refers to .${path}, which $(basename "${CF_ROOT_VALUES}") does not set" >&2
    exit 1
  fi
  printf '%s' "${v}"
}

# mode: external — fetch a chart from an OCI registry and install it like any other.
#
# For the apps that are not in the release tarball at all: AIM Engine and its CRDs are
# published to Docker Hub, and ArgoCD installs them straight from there. The three
# fields it reads are the ones ArgoCD reads -- repoURL:, chart:, repoVersion: -- so
# neither install path can be pointed at a different chart than the other.
#
# The chart is pulled and unpacked rather than rendered straight from the registry,
# because `helm template oci://...` re-downloads on every run and cannot be inspected
# when something looks wrong. Unpacked into the work directory, the exact chart that
# produced a render is still there afterwards.

# fetch_external_chart <app> : pull the app's chart out of its registry, setting
# CF_CHART_DIR to the directory it unpacked into and CF_CHART_REF to the reference it
# came from.
#
# Split out for uninstall-all.sh, which needs the same chart at the same version to
# render the objects it is about to delete -- including the CF_VERSION_ override below,
# since a cluster running ahead of the pin was installed from the newer chart and has to
# be deleted from the same one.
CF_CHART_REF=""
fetch_external_chart() {
  local app="$1" repo chart version override dir

  repo="$(resolve_values_template "${app}" "$(app_field "${app}" 'repoURL')")"
  chart="$(app_field "${app}" 'chart')"
  version="$(app_field "${app}" 'repoVersion')"

  if [ -z "${repo}" ] || [ -z "${chart}" ] || [ -z "${version}" ]; then
    echo "❌ ${app}: mode external requires repoURL:, chart: and repoVersion:" >&2
    exit 1
  fi

  # The same override install-old.sh offers, for a chart that has been published which no
  # cluster-forge release references yet. Announced rather than applied quietly: it
  # steps outside the set of versions the release was tested as a whole.
  override="CF_VERSION_$(printf '%s' "${app}" | tr 'a-z-' 'A-Z_')"
  if [ -n "${!override:-}" ]; then
    echo "ℹ️  ${app}: using ${!override} from ${override}, overriding ${version} from $(basename "${CF_ROOT_VALUES}")"
    version="${!override}"
  fi

  dir="${CF_WORK_DIR}/${app}.chart"
  rm -rf "${dir}"
  mkdir -p "${dir}"

  CF_CHART_REF="oci://${repo}/${chart}:${version}"
  echo "📥 Pulling ${CF_CHART_REF}..."
  retry helm pull "oci://${repo}/${chart}" --version "${version}" --untar --untardir "${dir}"

  # helm unpacks into a directory named after the chart's own name, which is not
  # necessarily the last segment of the repository path. Read back rather than
  # assumed, since the two agreeing is a convention and not a rule.
  CF_CHART_DIR="$(find "${dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [ ! -f "${CF_CHART_DIR}/Chart.yaml" ]; then
    echo "❌ ${app}: pulled ${CF_CHART_REF} but found no chart in ${dir}" >&2
    exit 1
  fi
}

install_external() {
  local app="$1"
  fetch_external_chart "${app}"
  install_core "${app}" "${CF_CHART_DIR}" "${CF_CHART_REF}"
}

# mode: objects — the step's whole payload is the objects the entry declares.
#
# For the steps install-old.sh writes as a run of `kubectl create secret --from-literal`
# and `kubectl create namespace` piped through apply: no chart, no file, nothing to
# render, just objects whose values come from the environment. Those are data, and
# expressing them as data is the point of this file -- a handler for them would be a
# heredoc in a shell script again, and unreadable to the operator that replaces it.
#
# The objects themselves are applied by apply_extra_objects and
# apply_extra_manifests, which run for every mode; this function exists to reject an
# entry that declares no payload at all, which would otherwise be a step that prints
# a banner and does nothing.
install_objects() {
  local app="$1" manifests maps
  manifests="$(yq ".apps.\"${app}\".extraManifests | length" "${CF_OPENSHIFT_VALUES}")"
  case "${manifests}" in ''|null) manifests=0 ;; esac
  maps="$(yq ".apps.\"${app}\".configMaps | length" "${CF_OPENSHIFT_VALUES}")"
  case "${maps}" in ''|null) maps=0 ;; esac
  if [ -z "$(app_field "${app}" 'extraObjects')" ] &&
     [ "${manifests}" = "0" ] && [ "${maps}" = "0" ]; then
    echo "❌ ${app}: mode objects requires extraObjects:, extraManifests: or configMaps:" >&2
    exit 1
  fi
}

# mode: custom — run the shell function the entry names in handler:.
#
# The escape hatch for steps whose logic is not expressible as data: host state
# changed over `oc debug`, secrets assembled from the environment, a chart
# applied three times around a webhook handshake. The entry still declares the
# step's tunables as ordinary fields, so a handler reads its configuration
# through app_field like every other mode and nothing about the step is buried
# in this file alone.
install_custom() {
  local app="$1" handler
  handler="$(app_field "${app}" 'handler')"
  if [ -z "${handler}" ]; then
    echo "❌ ${app}: mode custom requires handler: (the name of a shell function)" >&2
    exit 1
  fi
  # Resolved before calling, because bash reports a missing function as
  # "command not found", which reads like a missing binary and sends people
  # looking for the wrong problem.
  if ! declare -F "${handler}" >/dev/null; then
    echo "❌ ${app}: handler '${handler}' is not defined in this script" >&2
    exit 1
  fi
  "${handler}" "${app}"
}

# ============================================================================
# CUSTOM STEP: LOCAL-PATH PROVISIONER & DEFAULT STORAGE CLASS
# ============================================================================
# Four sub-steps that have to happen together, which is why this is one custom
# step and not four data-driven entries: the provisioner itself, the OpenShift
# SCC/SELinux fixes it needs, the host-side relabel of its backing directory,
# and the StorageClass that everything else defaults to.
step_local_path_storage() {
  local app="$1" ns manifest host_dir sc scc_file patch_file node defaults

  ns="$(app_namespace "${app}")"
  ns="${ns:-local-path-storage}"
  manifest="$(app_field "${app}" 'upstreamManifest')"
  host_dir="$(app_field "${app}" 'hostDir')"
  host_dir="${host_dir:-/var/opt/local-path-provisioner}"
  sc="$(app_field "${app}" 'defaultStorageClass')"
  sc="${sc:-default}"

  # ---- 1. the provisioner ---------------------------------------------------
  # RKE2 ships rancher.io/local-path built in, so the upstream manifest is
  # applied only where the StorageClass is missing entirely. The guard is not
  # just an optimisation: re-applying the manifest would revert the ConfigMap
  # patch made below.
  if kubectl get storageclass local-path >/dev/null 2>&1; then
    echo "ℹ️  local-path StorageClass already exists — skipping provisioner install"
  else
    if [ -z "${manifest}" ]; then
      echo "❌ ${app}: upstreamManifest: is required to install the provisioner" >&2
      exit 1
    fi
    echo "📦 Installing local-path provisioner from ${manifest}..."
    retry kubectl apply --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" -f "${manifest}"
    echo "⏳ Waiting for local-path provisioner to be ready..."
    kwait --for=condition=available --timeout=120s deployment/local-path-provisioner -n "${ns}"
    echo "✅ local-path provisioner is ready"
  fi

  # ---- 2. SCC and helper-pod SELinux context -------------------------------
  # The upstream manifest targets vanilla Kubernetes: it grants no SCC, and its
  # helper pod requests no SELinux context. On OpenShift that means every PVC
  # fails — first at admission ("hostPath volumes are not allowed to be used"),
  # then, once the SCC is granted, at mkdir ("Permission denied", because the
  # pod runs confined as container_t while /var/opt is var_t).
  #
  # Deliberately outside the guard above, so both parts are re-asserted on
  # every run.
  scc_file="${EXTRA_DIR}/02-local-path-provisioner-scc.yaml"
  patch_file="${EXTRA_DIR}/03-local-path-helper-pod-selinux.yaml"
  if ! kubectl get configmap local-path-config -n "${ns}" >/dev/null 2>&1; then
    # e.g. RKE2, where the built-in provisioner lives in kube-system instead.
    # Nothing to patch, so the manifests are not fetched either.
    echo "ℹ️  No local-path-config in ${ns} — skipping OpenShift SCC/SELinux fixes"
  else
    ensure_extra_file "${scc_file}"
    ensure_extra_file "${patch_file}"
    echo "🔧 Allowing the local-path helper pod to run under OpenShift SCC and SELinux..."
    ssa_apply < "${scc_file}"
    # A merge-patch fragment for the helperPod.yaml key, not a manifest, so this
    # one cannot go through ssa_apply.
    retry kubectl patch configmap local-path-config -n "${ns}" \
      --type merge --patch-file "${patch_file}"
    retry kubectl rollout restart deployment/local-path-provisioner -n "${ns}"
    kwait --for=condition=available --timeout=120s deployment/local-path-provisioner -n "${ns}"
    echo "✅ local-path helper pod can now provision volumes"
  fi

  # ---- 3. SELinux label on the backing directory ---------------------------
  # Volumes now get created, but consuming pods still cannot write to them.
  # RHCOS is SELinux Enforcing and /opt -> /var/opt is labelled var_t, so every
  # per-volume directory the helper pod creates inherits var_t. Consuming pods
  # run as container_t with MCS categories and are denied write on var_t. The
  # dirs are already 0777, so this is a label problem, not a permissions one.
  #
  # container_file_t at bare s0 is the right target: a process at s0:cX,cY
  # dominates s0, so every pod can write whatever categories it was assigned.
  # New per-volume dirs inherit the label, making this once per node rather than
  # once per volume.
  #
  # Host state, so there is no manifest for it — hence oc debug (no kubectl
  # equivalent) and cluster-admin.
  if ! command -v oc >/dev/null 2>&1; then
    echo "⚠️  oc not on PATH — skipping SELinux relabel of ${host_dir}."
    echo "    Pods will hit 'Permission denied' writing to volumes until it is done."
  else
    echo "🏷️  Labelling ${host_dir} for SELinux (one oc debug per node)..."
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
      echo "   → ${node}"
      oc debug "node/${node}" --quiet -- chroot /host /bin/bash -c "
        set -e
        mkdir -p '${host_dir}'
        semanage fcontext -a -t container_file_t '${host_dir}(/.*)?' 2>/dev/null \
          || semanage fcontext -m -t container_file_t '${host_dir}(/.*)?'
        restorecon -R '${host_dir}'
        ls -ldZ '${host_dir}'
      "
    done
    echo "✅ local-path backing directory labelled container_file_t"
  fi
  # NOTE: semanage writes to the node's local SELinux policy store, which the
  # Machine Config Operator does NOT manage. Nodes added later will not have
  # this, and an RHCOS upgrade may drop it. Convert to a MachineConfig for
  # anything beyond a small static cluster.

  # ---- 4. the StorageClass named "default" ---------------------------------
  # Required by name, not by role: otel-lgtm-stack's PVCs, the Keycloak CNPG
  # cluster and the rabbitmq/airm values all hardcode the literal string
  # "default" as their storageClassName, and install-old.sh passes it explicitly to
  # CNPG, SeaweedFS and Keycloak. Without a class by that name those PVCs stay
  # Pending no matter what the cluster default is.
  #
  # Created WITHOUT the is-default-class annotation on purpose — see the
  # separate check below.
  if kubectl get storageclass "${sc}" >/dev/null 2>&1; then
    echo "ℹ️  ${sc} StorageClass already exists"
  else
    echo "📦 Creating ${sc} StorageClass (rancher.io/local-path)..."
    ssa_apply <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
    echo "✅ ${sc} StorageClass created"
  fi

  # Claim the cluster-default role only if the seat is empty.
  #
  # Something has to hold it: OpenBao ships storageClass: null and is templated
  # with no override, so its PVC carries no class at all and binds to whatever
  # is cluster-default. But a cluster that already nominated one has real
  # storage behind it, and that choice outranks ours — an existing default is
  # never demoted, and the class created above never arrives pre-annotated,
  # which would otherwise leave two defaults. Kubernetes resolves that tie by
  # preferring the most recently created class, i.e. silently pulling every
  # class-less PVC in the cluster onto local-path.
  defaults="$(kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    2>/dev/null | grep '=true$' | cut -d= -f1 || true)"
  if [ -z "${defaults}" ]; then
    retry kubectl patch storageclass "${sc}" \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    echo "✅ ${sc} StorageClass marked as cluster default (no class held the role)"
  else
    echo "ℹ️  cluster default StorageClass is already $(echo "${defaults}" | paste -sd, -) — leaving it alone"
  fi

  echo "✅ ${app} ready"
}

# ============================================================================
# CUSTOM STEP: COPY OBJECTS UNDER A SECOND NAME
# ============================================================================
# Re-create objects that already exist under a different name, from the entry's
# copies: list. Generic rather than tied to one app, because the reason keeps
# recurring: a chart names an object one thing and another chart mounts it by a
# name it hardcodes, so one of the two has to be duplicated.
#
# Custom because the source is the cluster, not a file. Everything else in this
# script renders what to apply from the tarball; this reads an object back out of
# the API and re-applies it under another name, which no amount of data can
# express on its own.
#
# The copy is a snapshot. It does not track the original, so a step that changes
# the source leaves the copy behind at the old contents until this runs again.
step_copy_objects() {
  local app="$1" total i resource from to ns from_ns to_ns
  ns="$(app_namespace "${app}")"
  if [ -z "${ns}" ]; then
    echo "❌ ${app}: copies: needs namespace: to say where the objects live" >&2
    exit 1
  fi

  total="$(yq ".apps.\"${app}\".copies | length" "${CF_OPENSHIFT_VALUES}")"
  case "${total}" in
    ''|null|0)
      echo "❌ ${app}: handler step_copy_objects needs a copies: list" >&2
      exit 1
      ;;
  esac

  for (( i = 0; i < total; i++ )); do
    resource="$(yq ".apps.\"${app}\".copies[${i}].resource // \"\"" "${CF_OPENSHIFT_VALUES}")"
    from="$(yq ".apps.\"${app}\".copies[${i}].from // \"\"" "${CF_OPENSHIFT_VALUES}")"
    to="$(yq ".apps.\"${app}\".copies[${i}].to // \"\"" "${CF_OPENSHIFT_VALUES}")"
    if [ -z "${resource}" ] || [ -z "${from}" ] || [ -z "${to}" ]; then
      echo "❌ ${app}: copies[${i}] needs resource:, from: and to:" >&2
      exit 1
    fi

    # Both default to the app's namespace, so a copy within one namespace states
    # neither. They exist for the copies that cross a boundary: a certificate the
    # platform keeps in its own namespace, needed by a workload that cannot read it
    # there, since a Secret reference never spans namespaces.
    from_ns="$(yq ".apps.\"${app}\".copies[${i}].fromNamespace // \"\"" "${CF_OPENSHIFT_VALUES}")"
    to_ns="$(yq ".apps.\"${app}\".copies[${i}].toNamespace // \"\"" "${CF_OPENSHIFT_VALUES}")"
    from_ns="$(expand_env_refs "${app}" "${from_ns:-${ns}}")"
    to_ns="$(expand_env_refs "${app}" "${to_ns:-${ns}}")"
    from="$(expand_env_refs "${app}" "${from}")"
    to="$(expand_env_refs "${app}" "${to}")"

    if ! kubectl get "${resource}" "${from}" -n "${from_ns}" >/dev/null 2>&1; then
      echo "❌ ${app}: cannot copy ${resource}/${from} in ${from_ns}: it does not exist" >&2
      echo "   The step that creates it has to run before this one." >&2
      exit 1
    fi

    echo "📦 Copying ${resource}/${from} in ${from_ns} to ${resource}/${to} in ${to_ns}..."
    # Everything the API server owns is stripped, leaving a manifest that can be
    # applied as a new object. ownerReferences goes too, which install-old.sh does not
    # bother with: a copy that inherits the original's owner is garbage-collected
    # the moment that owner is deleted, which would look like the copy having
    # never been made.
    # metadata.namespace is rewritten rather than left to the --namespace flag:
    # kubectl refuses an object whose own namespace disagrees with the flag, and
    # the object read back carries the source namespace.
    kubectl get "${resource}" "${from}" -n "${from_ns}" -o yaml \
      | yq "del(.status,
               .metadata.resourceVersion,
               .metadata.uid,
               .metadata.creationTimestamp,
               .metadata.generation,
               .metadata.managedFields,
               .metadata.ownerReferences,
               .metadata.annotations.\"kubectl.kubernetes.io/last-applied-configuration\")
            | .metadata.name = \"${to}\"
            | .metadata.namespace = \"${to_ns}\"" \
      | ssa_apply -n "${to_ns}"
  done

  echo "✅ ${app} copied"
}

# ============================================================================
# CUSTOM STEP: AI GATEWAY POD-MUTATING WEBHOOK
# ============================================================================
# Check that the AI gateway's pod-mutating webhook is answering, and restart the
# controller if it is not.
#
# The envoy-ai-gateway chart mints a fresh self-signed certificate on every
# render, so each run rotates that webhook's keypair and caBundle together. The
# controller normally reloads the new certificate. If it ever did not, the webhook
# has failurePolicy: Fail on pod CREATE and would stop the Envoy data plane from
# ever being recreated, while leaving every other workload alone -- its
# objectSelector only matches app.kubernetes.io/managed-by: envoy-gateway. A
# cluster in that state looks healthy until something deletes an Envoy pod.
#
# Custom because it is neither an install nor a read-back: the question is whether
# admission accepts a pod it would mutate, which is answered by asking the API
# server to admit one and throw it away.
step_ai_gateway_webhook_probe() {
  local app="$1"

  # --dry-run=server runs the full admission chain, this webhook included, and
  # persists nothing. The labels are what its objectSelector matches; without them
  # the webhook is never consulted and the probe proves nothing.
  probe_pod() {
    kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'PROBE'
apiVersion: v1
kind: Pod
metadata:
  name: ai-gateway-webhook-probe
  namespace: envoy-gateway-system
  labels:
    app.kubernetes.io/managed-by: envoy-gateway
spec:
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "1"]
PROBE
  }

  if probe_pod; then
    echo "✅ ${app}: pod-mutating webhook is admitting pods"
    return 0
  fi

  echo "⚠️  ${app}: the pod-mutating webhook is rejecting pods; restarting the controller to reload its certificate"
  kubectl rollout restart deploy/ai-gateway-controller -n envoy-ai-gateway-system
  kubectl rollout status deploy/ai-gateway-controller -n envoy-ai-gateway-system --timeout=180s

  if probe_pod; then
    echo "✅ ${app}: webhook healthy after the restart"
    return 0
  fi

  # Fatal, unlike install-old.sh, which prints the same finding and carries on. A
  # webhook rejecting pods means the data plane cannot be recreated, and every
  # later step that expects the gateway to serve would fail further from the cause.
  echo "❌ ${app}: the webhook is still rejecting pods after a controller restart." >&2
  echo "   The Envoy data plane cannot be recreated until this is fixed. Check:" >&2
  echo "     kubectl logs -n envoy-ai-gateway-system deploy/ai-gateway-controller" >&2
  exit 1
}

# ============================================================================
# CUSTOM STEP: WORKSPACE STORAGECLASSES
# ============================================================================
# Two more StorageClasses for workspace PVCs. Custom rather than extraObjects
# because the semantics are create-if-absent, not apply: provisioner is an
# immutable field, so applying over a class that someone else created on real
# storage would fail the whole run, and succeeding would be worse.
#
# NAMES ARE MISLEADING, and this is worth knowing before sizing anything on
# them. Both are rancher.io/local-path with the same host directory and no
# parameters, identical to the default and local-path classes created earlier.
# All four are aliases; there are no separate pools and no shared storage behind
# any of them. In particular multinode CANNOT do RWX — it only appears to,
# because local-path-access-mode-mutation rewrites RWX/ROX to RWO before
# anything notices, and all four names are hard-coded in that policy's
# precondition. Backing one of these names with real shared storage later means
# removing it from the policy first, and recreating any PVC already converted,
# since accessModes is immutable.
step_workspace_storageclasses() {
  local app="$1" provisioner name existing

  provisioner="$(app_field "${app}" 'provisioner')"
  provisioner="${provisioner:-rancher.io/local-path}"

  while read -r name; do
    [ -z "${name}" ] && continue
    existing="$(kubectl get storageclass "${name}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
    if [ -n "${existing}" ]; then
      # Reported rather than silently skipped: a class of this name backed by
      # something else means the aliasing assumption above no longer holds, and
      # workspace PVCs are landing on storage nobody here chose.
      if [ "${existing}" != "${provisioner}" ]; then
        echo "⚠️  ${name} StorageClass already exists with provisioner ${existing}, not ${provisioner} — left untouched"
      else
        echo "ℹ️  ${name} StorageClass already exists"
      fi
      continue
    fi
    echo "📦 Creating ${name} StorageClass (${provisioner})..."
    ssa_apply <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${name}
provisioner: ${provisioner}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
  done < <(yq ".apps.\"${app}\".storageClasses[]" "${CF_OPENSHIFT_VALUES}")

  echo "✅ ${app} ready"
}

# ============================================================================
# ALREADY-PROVIDED CHECK
# ============================================================================
# skipInstallWhenExists names an object whose presence means the payload is
# already on the cluster under another owner, so applying our copy would fight
# whoever put it there rather than add anything.
#
# Distinct from skipWhen, which drops the whole app: this skips only the install.
# Patches, extra objects and verify still run, so the step still asserts the end
# state it requires and merely stops claiming to be what produced it.
#
# name: is optional. Without it the test is whether any object of that kind exists
# at all, in every namespace unless one is named, for the case where what matters is
# that something already did this job and not what it called the result. The GPU
# operator's DeviceConfig is that case: a second one selecting the same nodes gives
# them a second device plugin advertising the same GPUs.
#
# CF_SKIP_REASON is set for the caller to print, since only this function knows
# which of the two forms was asked for.
#
# selector: is the third form, for a step whose work is already evident in the state
# of the cluster rather than in an object of its own. The NodeFeatureRule fallback is
# that: it exists to put a label on the GPU nodes, so the question is whether a node
# already carries the label, not whether some rule object exists.
CF_SKIP_REASON=""
install_already_provided() {
  local app="$1" resource name selector ns
  local -a ns_args=() selector_args=()

  resource="$(app_field "${app}" 'skipInstallWhenExists.resource')"
  if [ -z "${resource}" ]; then
    return 1
  fi
  name="$(app_field "${app}" 'skipInstallWhenExists.name')"
  selector="$(expand_env_refs "${app}" "$(app_field "${app}" 'skipInstallWhenExists.selector')")"

  ns="$(expand_env_refs "${app}" "$(app_field "${app}" 'skipInstallWhenExists.namespace')")"
  [ -n "${ns}" ] && ns_args=(--namespace "${ns}")

  if [ -n "${name}" ]; then
    CF_SKIP_REASON="${resource}/${name}${ns:+ in ${ns}}"
    kubectl get "${resource}" "${name}" "${ns_args[@]}" >/dev/null 2>&1
    return
  fi

  [ -z "${ns}" ] && ns_args=(--all-namespaces)
  if [ -n "${selector}" ]; then
    selector_args=(-l "${selector}")
    CF_SKIP_REASON="a ${resource} matching ${selector}${ns:+ in ${ns}}"
  else
    CF_SKIP_REASON="a ${resource}${ns:+ in ${ns}}"
  fi
  [ -n "$(kubectl get "${resource}" "${selector_args[@]}" "${ns_args[@]}" -o name 2>/dev/null)" ]
}

# ============================================================================
# INSTALL LOOP
# ============================================================================
# Walks values-openshift.yaml in declaration order. Everything about which apps
# exist and in what order lives in that file, so this loop never names one.
#
# CF_LIB_ONLY=true stops here: uninstall-all.sh sources this file for its
# functions, the release tarball it has already unpacked and the environment it
# discovered from the cluster, and then walks the same order backwards. Everything
# above this point either defines something or reads the cluster, so sourcing it
# changes nothing; the loop below is the only part that installs, and a script
# whose job is to delete must not run it on the way in.
# True when this run should install <app>. An empty CF_ONLY is a full walk; otherwise
# only the named keys, so a chart-version override like CF_VERSION_AIWB can be applied
# without replaying the rest of the order.
install_wants_app() {
  local app="$1" want
  [ "${#CF_ONLY[@]}" -eq 0 ] && return 0
  for want in "${CF_ONLY[@]}"; do
    [ "${want}" = "${app}" ] && return 0
  done
  return 1
}

install_all() {
  local app app_name app_skip_when skip_var skip_val app_mode

  if [ "${#CF_ONLY[@]}" -gt 0 ]; then
    echo "ℹ️  Installing only: ${CF_ONLY[*]}"
  fi

  for app in "${CF_APPS[@]}"; do
    install_wants_app "${app}" || continue

    app_name="$(app_field "${app}" 'name')"

    # skipWhen: VAR=value — some apps exist only in one deployment shape (an
    # external database, an external object store), and install-old.sh expresses that
    # with an if around the step. Evaluated before the banner so a skipped app
    # does not consume a step number and read as a phase that was carried out.
    app_skip_when="$(app_field "${app}" 'skipWhen')"
    if [ -n "${app_skip_when}" ]; then
      skip_var="${app_skip_when%%=*}"
      skip_val="${app_skip_when#*=}"
      if [ "${!skip_var:-}" = "${skip_val}" ]; then
        echo ""
        echo "⏭️  ${app_name:-${app}}: skipped, ${skip_var}=${skip_val}"
        continue
      fi
    fi

    if [ "${app}" = "aim-cluster-model-source" ]; then
      discover_aim_hardware_families
      if [ -z "${CF_AIM_HARDWARE_FAMILIES:-}" ]; then
        echo ""
        echo "⏭️  ${app_name:-${app}}: skipped — no amd.com/gpu.product-name labels matching Instinct or Radeon found on any node"
        continue
      fi
    fi

    step "${app_name:-${app}}"

    # Everything this step applies is owned as this step, so a later step sharing an
    # object with it merges rather than replaces. It is also the answer to "who set
    # this field", which on a cluster carrying leftovers from ArgoCD, helm, install-old.sh
    # and a UI is a question that gets asked often.
    CF_FIELD_MANAGER="cluster-forge/${app}"

    apply_patches "${app}" pre

    app_mode="$(app_field "${app}" 'mode')"
    if install_already_provided "${app}"; then
      echo "ℹ️  ${app}: ${CF_SKIP_REASON} already present — not installing our own copy"
      app_mode=skip-install
    else
      # Only when the step is actually going to install: an app whose copy the
      # platform already provides must not have that copy deleted.
      apply_delete_before "${app}"
    fi
    case "${app_mode}" in
      skip-install)
        ;;
      extra)
        install_extra "${app}"
        ;;
      core)
        install_core "${app}"
        ;;
      custom)
        install_custom "${app}"
        ;;
      external)
        install_external "${app}"
        ;;
      objects)
        install_objects "${app}"
        ;;
      *)
        # Fatal rather than skipped: a typo in mode: must not quietly drop an app
        # out of the install.
        echo "❌ ${app}: unknown mode '${app_mode}' in $(basename "${CF_OPENSHIFT_VALUES}")" >&2
        exit 1
        ;;
    esac

    apply_config_maps "${app}"
    apply_extra_objects "${app}"
    apply_extra_manifests "${app}"
    apply_patches "${app}" post

    # Deliberately outside the case: what a step must leave behind is a property
    # of the step, not of how it was installed, so every mode is checked the same
    # way and a custom handler cannot quietly opt out.
    run_verify "${app}"
  done

  if [ "${#CF_ONLY[@]}" -gt 0 ]; then
    echo ""
    echo "✅ Install order complete (${CF_ONLY[*]})"
    cf_print_elapsed
    return 0
  fi

  echo ""
  echo "🤖 Inference endpoint (all served models share this hostname):"
  echo "   https://${AI_HOST}/v1/chat/completions"
  echo ""
  echo "   Which model answers is decided by the headers, not the path or host."
  echo "   -k is needed while the router still serves a self-signed certificate."
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
  echo "💡 Keycloak Admin Credentials:"
  echo "   Username: silogen-admin"
  echo "   Password: ${KEYCLOAK_INITIAL_ADMIN_PASSWORD}"
  echo "   Admin Console: http://${DOMAIN}:8080/admin"
  echo ""
  echo "💡 AIWB User Login:"
  echo "   Username: devuser@${DOMAIN}"
  echo "   Password: ${KEYCLOAK_INITIAL_DEVUSER_PASSWORD}"
  echo ""
  echo "📊 Observability (Grafana, Prometheus, Loki, Tempo):"
  echo "   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000"
  echo "   Access Grafana at: http://localhost:3000"
  echo "   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090"
  echo "   Access Prometheus at: http://localhost:9090"
  echo ""
  echo "ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md"
  echo ""
  echo "✅ Install order complete"
  cf_print_elapsed
}

# ============================================================================
# OPTIONS
# ============================================================================
# Positional app keys, or CF_ONLY, restrict the walk to those steps. Same names
# as uninstall-all.sh: the keys under apps: in values-openshift.yaml (aiwb, not
# "AIWB application"). Used to re-apply one chart after a CF_VERSION_* override
# without reinstalling the rest. Parsed only when this file is the installer,
# never when uninstall-all.sh sources it (that script has its own CF_ONLY).

if [ "${CF_LIB_ONLY:-false}" != "true" ]; then
  cf_only_arg="${CF_ONLY:-}"
  CF_ONLY=()
  CF_LIST=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --list)    CF_LIST=true ;;
      -h|--help) exit 0 ;;
      -*)        echo "❌ unknown option: $1" >&2; exit 1 ;;
      *)         CF_ONLY+=("$1") ;;
    esac
    shift
  done

  if [ "${#CF_ONLY[@]}" -eq 0 ] && [ -n "${cf_only_arg}" ]; then
    read -ra CF_ONLY <<< "${cf_only_arg//,/ }"
  fi

  for want in ${CF_ONLY[@]+"${CF_ONLY[@]}"}; do
    found=false
    for app in "${CF_APPS[@]}"; do
      [ "${app}" = "${want}" ] && found=true && break
    done
    if [ "${found}" != true ]; then
      echo "❌ no app '${want}' in $(basename "${CF_OPENSHIFT_VALUES}")" >&2
      echo "   --list prints the names." >&2
      exit 1
    fi
  done

  if [ "${CF_LIST}" = true ]; then
    echo ""
    echo "Install order (${#CF_APPS[@]} apps):"
    n=0
    for app in "${CF_APPS[@]}"; do
      n=$((n + 1))
      echo "  ${n}. ${app}  $(app_field "${app}" 'name')"
    done
    exit 0
  fi

  install_all
fi
