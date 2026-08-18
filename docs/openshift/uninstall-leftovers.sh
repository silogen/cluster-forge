#!/usr/bin/env bash
# ============================================================================
# AFTER THE UNINSTALL WALK
# ============================================================================
# uninstall-operator.sh deletes what each install step declared. That is the reverse of
# setup-operator.sh, and it is enough for charts and extraObjects. It is not enough for
# what never appears in a render:
#
#   - namespaces the install created with `kubectl create namespace` (no chart owns them,
#     and mid-walk deletion would cascade other steps' content)
#   - cluster-scoped objects controllers wrote at runtime (Kyverno's webhooks, for example)
#   - objects an older install path put on the cluster that today's chart values no longer
#     emit (OpenBao's agent injector when injector.enabled is false)
#
# This script is that second half. Run it after uninstall-operator.sh has walked the order
# (or after the OpenShift operator's uninstall has done the same). Dry run unless --delete.
#
# Order matters only for clarity: unclaimed objects first (what no step's render names,
# whether cluster-scoped or not), then the namespace sweep (workbench runtime, PVCs, and
# whatever else is still namespaced).
#
# Usage:
#
#   KUBECONFIG=docs/openshift/kube.yaml ./uninstall-leftovers.sh
#   KUBECONFIG=docs/openshift/kube.yaml ./uninstall-leftovers.sh --delete
#   KUBECONFIG=docs/openshift/kube.yaml ./uninstall-leftovers.sh --delete --step

set -euo pipefail

CF_DELETE=false
CF_STEP=false
CF_LIST=false
CF_ONLY_ORPHANS=false
CF_ONLY_NAMESPACES=false

usage() {
  cat <<'EOF'
Usage: uninstall-leftovers.sh [options]

Deletes what uninstall-operator.sh cannot claim: objects no step's render names
(Kyverno webhooks, the OpenBao agent injector), and the namespaces the install left
standing. Dry run unless --delete.

  --delete              actually delete (default: dry run)
  --step                ask before each phase: [y]es, [n]o to skip it, [q]uit
  --list                print what this script targets and exit
  --orphans             only the unclaimed objects (webhooks, OpenBao injector, …)
  --namespaces          only the namespace sweep
  -h, --help            this

Intended to run after uninstall-operator.sh (or the OpenShift operator uninstall that
mirrors it). Does not touch local-path-storage, openshift-*, or namespaces that still
hold an OLM Subscription.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --delete)           CF_DELETE=true ;;
    --step)             CF_STEP=true ;;
    --list)             CF_LIST=true ;;
    --orphans|--cluster-scoped) CF_ONLY_ORPHANS=true ;;
    --namespaces)       CF_ONLY_NAMESPACES=true ;;
    -h|--help)          usage; exit 0 ;;
    -*)                 echo "❌ unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                  echo "❌ unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ "${CF_ONLY_ORPHANS}" = true ] && [ "${CF_ONLY_NAMESPACES}" = true ]; then
  echo "❌ --orphans and --namespaces are alternatives, not both" >&2
  exit 1
fi

# Namespaces emptied by the uninstall walk and left for one final pass. Same set as
# uninstall-namespaces.md. workbench and seaweedfs-instance stay last: they hold the
# largest volumes, and watching them terminate after the empty ones is more readable.
CF_NAMESPACES=(
  kaiwo-system
  kueue-system
  rabbitmq-system
  seaweedfs-operator
  cluster-auth
  keycloak
  aiwb
  airm
  demo
  metallb-system
  minio-tenant-default
  aim-system
  kserve-system
  envoy-ai-gateway-system
  envoy-gateway-system
  keda
  otel-lgtm-stack
  cf-openbao
  external-secrets
  opentelemetry-system
  cert-manager
  kyverno
  appwrapper-system
  cnpg-system
  seaweedfs-instance
  workbench
)

# namespace_kept <name> : true for a namespace this script must not delete.
CF_KEEP_REASON=""
namespace_kept() {
  local ns="$1"
  case "${ns}" in
    default|kube-*|openshift-*|local-path-storage)
      CF_KEEP_REASON="a platform namespace"
      return 0
      ;;
  esac
  if [ -n "$(kubectl get subscriptions.operators.coreos.com -n "${ns}" -o name 2>/dev/null)" ]; then
    CF_KEEP_REASON="an OLM-installed operator lives there"
    return 0
  fi
  return 1
}

confirm() {
  local prompt="$1" reply
  [ "${CF_STEP}" = true ] || return 0
  while true; do
    read -r -p "${prompt} [y/n/q] " reply
    case "${reply}" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      q|Q) echo "stopped."; exit 0 ;;
    esac
  done
}

delete_or_print() {
  local resource="$1"
  if ! kubectl get "${resource}" >/dev/null 2>&1; then
    echo "   already gone: ${resource}"
    return 0
  fi
  if [ "${CF_DELETE}" = true ]; then
    echo "   🗑️  ${resource}"
    kubectl delete "${resource}" --wait=false
  else
    echo "   would delete ${resource}"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: unclaimed objects (no step's render names them)
# ---------------------------------------------------------------------------
# Kyverno registers its webhooks itself; the chart never lists them, so the walk cannot
# delete them. OpenBao's injector was applied by an older install path; today's values set
# injector.enabled=false, so the walk's render names none of it — not the webhook, not the
# RBAC, and not the Deployment/Service/SA in cf-openbao. The namespace sweep would still
# take the namespaced half, but listing the whole injector here keeps one leftover in one
# place and lets --orphans clear it without deleting the namespace.
sweep_orphans() {
  local r
  local -a targets=()

  echo ""
  echo "════════════════ [LEFTOVERS 1/2] unclaimed objects ════════════════"

  while IFS= read -r r; do
    [ -n "${r}" ] && targets+=("${r}")
  done < <(
    kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name 2>/dev/null \
      | grep -E 'kyverno|openbao-agent-injector' || true
  )
  for r in \
    clusterrole/openbao-agent-injector-clusterrole \
    clusterrolebinding/openbao-agent-injector-binding \
    deploy/openbao-agent-injector \
    svc/openbao-agent-injector-svc \
    sa/openbao-agent-injector
  do
    case "${r}" in
      deploy/*|svc/*|sa/*)
        kubectl get "${r}" -n cf-openbao >/dev/null 2>&1 && targets+=("${r}|cf-openbao")
        ;;
      *)
        kubectl get "${r}" >/dev/null 2>&1 && targets+=("${r}")
        ;;
    esac
  done

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "   nothing to delete"
    return 0
  fi

  confirm "Delete ${#targets[@]} unclaimed leftover(s)?" || {
    echo "   skipped"
    return 0
  }

  for r in "${targets[@]}"; do
    if [[ "${r}" == *'|'* ]]; then
      delete_or_print_ns "${r%%|*}" "${r#*|}"
    else
      delete_or_print "${r}"
    fi
  done
}

delete_or_print_ns() {
  local resource="$1" ns="$2"
  if ! kubectl get "${resource}" -n "${ns}" >/dev/null 2>&1; then
    echo "   already gone: ${resource} in ${ns}"
    return 0
  fi
  if [ "${CF_DELETE}" = true ]; then
    echo "   🗑️  ${resource} in ${ns}"
    kubectl delete "${resource}" -n "${ns}" --wait=false
  else
    echo "   would delete ${resource} in ${ns}"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2: namespace sweep
# ---------------------------------------------------------------------------
sweep_namespaces() {
  local ns present=() kept=() missing=()
  echo ""
  echo "════════════════ [LEFTOVERS 2/2] namespaces ════════════════"

  for ns in "${CF_NAMESPACES[@]}"; do
    if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
      missing+=("${ns}")
      continue
    fi
    if namespace_kept "${ns}"; then
      kept+=("${ns}|${CF_KEEP_REASON}")
      continue
    fi
    present+=("${ns}")
  done

  for ns in "${missing[@]}"; do
    echo "   already gone: namespace/${ns}"
  done
  for entry in "${kept[@]}"; do
    echo "   🔒 kept namespace/${entry%%|*} — ${entry#*|}"
  done

  if [ "${#present[@]}" -eq 0 ]; then
    echo "   nothing to delete"
    return 0
  fi

  confirm "Delete ${#present[@]} namespace(s) (cascades everything inside)?" || {
    echo "   skipped"
    return 0
  }

  for ns in "${present[@]}"; do
    if [ "${CF_DELETE}" = true ]; then
      echo "   🗑️  namespace/${ns}"
      kubectl delete namespace "${ns}" --wait=false
    else
      echo "   would delete namespace/${ns}"
    fi
  done

  if [ "${CF_DELETE}" = true ] && [ "${#present[@]}" -gt 0 ]; then
    echo ""
    echo "   namespaces were asked to delete; termination is asynchronous (finalizers, PVCs)."
    echo "   watch with: kubectl get ns ${present[*]}"
  fi
}

if [ "${CF_LIST}" = true ]; then
  echo ""
  echo "Unclaimed leftovers (matched on the live cluster when the script runs):"
  echo "  validating/mutating webhookconfigurations matching kyverno|openbao-agent-injector"
  echo "  clusterrole/openbao-agent-injector-clusterrole"
  echo "  clusterrolebinding/openbao-agent-injector-binding"
  echo "  deploy/svc/sa openbao-agent-injector* in cf-openbao"
  echo ""
  echo "Namespaces (${#CF_NAMESPACES[@]}), in sweep order:"
  local_i=0
  for ns in "${CF_NAMESPACES[@]}"; do
    local_i=$((local_i + 1))
    printf '  %2d. %s\n' "${local_i}" "${ns}"
  done
  exit 0
fi

echo ""
if [ "${CF_DELETE}" = true ]; then
  echo "🔥 Leftovers teardown from $(kubectl config current-context 2>/dev/null || echo 'the current context')"
else
  echo "👀 Dry run of leftovers teardown. Nothing will be deleted."
  echo "   Add --delete to carry it out, --step to be asked before each phase."
fi

do_orphans=true
do_namespaces=true
[ "${CF_ONLY_NAMESPACES}" = true ] && do_orphans=false
[ "${CF_ONLY_ORPHANS}" = true ] && do_namespaces=false

[ "${do_orphans}" = true ] && sweep_orphans
[ "${do_namespaces}" = true ] && sweep_namespaces

echo ""
if [ "${CF_DELETE}" = true ]; then
  echo "✅ leftovers pass finished"
else
  echo "👀 Dry run finished — re-run with --delete to apply"
fi
