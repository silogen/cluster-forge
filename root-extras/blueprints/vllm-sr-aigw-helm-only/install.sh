#!/usr/bin/env bash
# Install the vLLM Semantic Router + Envoy AI Gateway + token-quota stack on a
# generic Kubernetes cluster with plain Helm. No ArgoCD, no Gitea, no
# cluster-forge. Re-runnable: every step is `helm upgrade --install` or an
# idempotent `kubectl apply`.
#
# See README.md. Configure with environment variables:
#
#   AIGW_CONTROLLER_IMAGE   full repo:tag of a patched AI Gateway controller
#                           (needed for working per-tenant token quota)
#   AIGW_EXTPROC_IMAGE      full repo:tag of the matching extproc build
#   AIGW_CHART              path to ai-gateway-helm       (default: vendored v1.0.0)
#   AIGW_CRDS_CHART         path to ai-gateway-crds-helm  (default: vendored v1.0.0)
#   SR_CHART                path to the semantic-router chart
#                           (default: shallow clone of the pinned commit)
#   SR_VALUES               semantic-router values file   (default: values/semantic-router.yaml)
#   SR_REPO                 semantic-router git repo      (default: upstream vllm-project/semantic-router)
#   SR_COMMIT               semantic-router pinned commit (default: 342d4523cceb0145448f78a61eb9b0334e23e6f8)
#   CLIENT_KEY_NAME         name of the first API key     (default: default-client)
#   DRY_RUN=1               render and server-validate everything, change nothing
#
# Namespace is fixed at "semantic-router" — every manifest under manifests/
# hardcodes that namespace (Gateway, SecurityPolicy, extProc backendRef,
# QuotaPolicy), so it is not a safe override point.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SOURCES_DIR="${SOURCES_DIR:-$REPO_ROOT/sources}"

EG_CHART="${EG_CHART:-$SOURCES_DIR/envoy-gateway/v1.8.1}"
AIGW_CRDS_CHART="${AIGW_CRDS_CHART:-$SOURCES_DIR/envoy-ai-gateway-crds/v1.0.0}"
AIGW_CHART="${AIGW_CHART:-$SOURCES_DIR/envoy-ai-gateway/v1.0.0}"
RATELIMIT_CHART="${RATELIMIT_CHART:-$SOURCES_DIR/envoy-ai-gateway-ratelimit/0.1.0}"

# Pinned commit must have Chart.yaml appVersion set to a real released tag
# (e.g. "v0.3.0"), not "latest" -- older chart commits default appVersion to
# "latest", which floats forward on ghcr.io independently of this chart's own
# config schema and eventually breaks with "deprecated config fields ... no
# longer supported" once upstream's router binary outpaces what this chart
# emits. Verify after bumping: `grep appVersion .cache/semantic-router/deploy/helm/semantic-router/Chart.yaml`.
SR_REPO="${SR_REPO:-https://github.com/vllm-project/semantic-router.git}"
SR_COMMIT="${SR_COMMIT:-342d4523cceb0145448f78a61eb9b0334e23e6f8}"
SR_CHART="${SR_CHART:-}"
SR_VALUES="${SR_VALUES:-$SCRIPT_DIR/values/semantic-router.yaml}"

NAMESPACE=semantic-router
CLIENT_KEY_NAME="${CLIENT_KEY_NAME:-default-client}"
KEY_SECRET="semantic-router-client-keys"

EG_NS=envoy-gateway-system
AIGW_NS=envoy-ai-gateway-system

DRY_RUN="${DRY_RUN:-}"
HELM_EXTRA=()
KUBECTL_EXTRA=()
if [[ -n "$DRY_RUN" ]]; then
  HELM_EXTRA=(--dry-run)
  KUBECTL_EXTRA=(--dry-run=server)
fi

log()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Wait for every Deployment in a namespace to report Available. Skipped under
# DRY_RUN, where nothing was actually created.
wait_ready() {
  local ns=$1 timeout=${2:-5m}
  [[ -n "$DRY_RUN" ]] && return 0
  kubectl -n "$ns" wait --for=condition=Available deployment --all --timeout="$timeout"
}

# Split a full image ref into --set repository/tag. Splitting on the last colon
# is correct for registry:port/name:tag, but silently wrong for a ref with no
# tag at all -- so require one.
image_set() {
  local prefix=$1 ref=$2
  case "${ref##*/}" in
    *:*) ;;
    *) die "$prefix image '$ref' has no tag. Use repo:tag." ;;
  esac
  printf '%s\n%s\n' "--set=${prefix}.image.repository=${ref%:*}" "--set=${prefix}.image.tag=${ref##*:}"
}

# ---------------------------------------------------------------- 0. preflight
log "Preflight"

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
command -v git     >/dev/null || die "git not found"
command -v openssl >/dev/null || die "openssl not found"

kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Check your kubeconfig."
helm version --short >/dev/null || die "helm is not usable"

for chart in "$EG_CHART" "$AIGW_CRDS_CHART" "$AIGW_CHART" "$RATELIMIT_CHART"; do
  [[ -d "$chart" ]] || die "chart directory not found: $chart"
done
[[ -f "$SR_VALUES" ]] || die "values file not found: $SR_VALUES"

# A TODO placeholder is not a legal Kubernetes name, so this would fail on
# apply anyway -- failing here just names the files instead of one field.
todo_files=()
for f in "$SR_VALUES" "$SCRIPT_DIR"/manifests/gateway-routing.yaml "$SCRIPT_DIR"/manifests/quota.yaml; do
  if [[ -f "$f" ]] && grep -q 'TODO-' "$f"; then
    todo_files+=("$f")
  fi
done
if (( ${#todo_files[@]} )); then
  printf 'ERROR: unfilled TODO placeholders remain in:\n' >&2
  printf '  %s\n' "${todo_files[@]}" >&2
  printf 'Edit them (grep -n TODO- <file>) before installing. Delete manifests/quota.yaml if you do not want token quotas.\n' >&2
  exit 1
fi

if grep -qE '^\s*storageClassName:\s*""' "$SR_VALUES"; then
  if ! kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q true; then
    warn "$SR_VALUES leaves storageClassName empty but this cluster has no default StorageClass. The router's PVC will stay Pending. Set a real class name."
  fi
fi

AIGW_SETS=()
if [[ -n "${AIGW_CONTROLLER_IMAGE:-}" ]]; then
  while IFS= read -r s; do AIGW_SETS+=("$s"); done < <(image_set controller "$AIGW_CONTROLLER_IMAGE")
else
  warn "AIGW_CONTROLLER_IMAGE not set: installing the upstream AI Gateway controller.
   Routing, auth and token accounting work. PER-TENANT TOKEN QUOTA DOES NOT --
   each key's enforced counter increments by 1 per request while real token cost
   pools into one shared bucket. See 'Build the patched AI Gateway image' in README.md."
fi
if [[ -n "${AIGW_EXTPROC_IMAGE:-}" ]]; then
  while IFS= read -r s; do AIGW_SETS+=("$s"); done < <(image_set extProc "$AIGW_EXTPROC_IMAGE")
fi

# semantic-router's chart is not vendored in this repo; fetch the pinned commit.
if [[ -z "$SR_CHART" ]]; then
  src="$SCRIPT_DIR/.cache/semantic-router"
  if [[ ! -d "$src/.git" ]]; then
    log "Fetching semantic-router chart ($SR_COMMIT)"
    rm -rf "$src"
    mkdir -p "$src"
    git -C "$src" init -q
    git -C "$src" remote add origin "$SR_REPO"
  fi
  if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$SR_COMMIT" ]]; then
    git -C "$src" fetch -q --depth 1 origin "$SR_COMMIT"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  SR_CHART="$src/deploy/helm/semantic-router"
  [[ -d "$SR_CHART/charts" ]] || helm dependency build "$SR_CHART"
fi
[[ -d "$SR_CHART" ]] || die "semantic-router chart not found: $SR_CHART"

# ------------------------------------------------------------ 1. Envoy Gateway
log "Envoy Gateway"
helm upgrade --install envoy-gateway "$EG_CHART" \
  -n "$EG_NS" --create-namespace \
  -f "$SCRIPT_DIR/values/envoy-gateway.yaml" \
  --wait --timeout 5m "${HELM_EXTRA[@]}"
wait_ready "$EG_NS"

log "GatewayClass"
kubectl apply -f "$SCRIPT_DIR/gatewayclass.yaml" "${KUBECTL_EXTRA[@]}"

# --------------------------------------------------------- 2. AI Gateway (CRDs)
log "AI Gateway CRDs"
helm upgrade --install envoy-ai-gateway-crds "$AIGW_CRDS_CHART" \
  -n "$AIGW_NS" --create-namespace \
  --wait --timeout 5m "${HELM_EXTRA[@]}"

log "AI Gateway controller"
helm upgrade --install envoy-ai-gateway "$AIGW_CHART" \
  -n "$AIGW_NS" \
  -f "$SCRIPT_DIR/values/envoy-ai-gateway.yaml" \
  "${AIGW_SETS[@]+"${AIGW_SETS[@]}"}" \
  --wait --timeout 5m "${HELM_EXTRA[@]}"
wait_ready "$AIGW_NS"

# ------------------------------------------------------- 3. rate limit + Redis
# What QuotaPolicy actually counts against. Without it QuotaPolicy loads and
# throttles nobody -- the controller fails open.
log "Rate limit service + Redis"
helm upgrade --install envoy-ai-gateway-ratelimit "$RATELIMIT_CHART" \
  -n "$EG_NS" \
  --wait --timeout 5m "${HELM_EXTRA[@]}"
wait_ready "$EG_NS"

# --------------------------------------------------------- 4. client API keys
log "Namespace and client API keys"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - "${KUBECTL_EXTRA[@]}"

if [[ -n "$DRY_RUN" ]]; then
  echo "(dry run: skipping API key Secret)"
elif kubectl -n "$NAMESPACE" get secret "$KEY_SECRET" >/dev/null 2>&1; then
  echo "Secret $KEY_SECRET already exists, leaving it alone. Key names in it:"
  kubectl -n "$NAMESPACE" get secret "$KEY_SECRET" -o go-template='{{range $k, $v := .data}}  {{$k}}{{"\n"}}{{end}}'
else
  key="$(openssl rand -hex 32)"
  kubectl -n "$NAMESPACE" create secret generic "$KEY_SECRET" --from-literal="$CLIENT_KEY_NAME=$key"
  cat <<EOF

  ########################################################################
  #  Client API key created. It is NOT printed again -- save it now.
  #
  #    key name : $CLIENT_KEY_NAME
  #    key      : $key
  #
  #  Use it as:  Authorization: Bearer $key
  #  The key NAME is what per-key quota buckets on. Never reuse a name for
  #  a different tenant -- it inherits the old tenant's accumulated spend.
  ########################################################################

EOF
fi

# ------------------------------------------------------------ 5. the router
# First boot downloads a ~500 MB embedding model into the PVC, so this is slow
# the first time and fast afterwards.
log "semantic-router (first boot downloads a ~500 MB model, be patient)"
helm upgrade --install semantic-router "$SR_CHART" \
  -n "$NAMESPACE" \
  -f "$SR_VALUES" \
  --wait --timeout 10m "${HELM_EXTRA[@]}"

# --------------------------------------------------------- 6. gateway wiring
# ORDER MATTERS, do not turn this into a glob. If the AIGatewayRoute is
# reconciled before its parentRef Gateway exists, the controller logs "Gateway
# not found" and leaves the pushed RouteConfiguration with zero virtual_hosts
# permanently, with no retry -- see manifests/gateway-routing.yaml.
log "Gateway wiring"
for m in sr-gateway-config.yaml \
         sr-gateway-proxy-config.yaml \
         sr-gateway.yaml \
         sr-gateway-service.yaml \
         sr-gateway-extproc.yaml \
         gateway-routing.yaml \
         quota.yaml; do
  f="$SCRIPT_DIR/manifests/$m"
  [[ -f "$f" ]] || { echo "skipping absent $m"; continue; }
  kubectl apply -f "$f" "${KUBECTL_EXTRA[@]}"
done

if [[ -z "$DRY_RUN" ]]; then
  echo
  echo "Waiting for the sr-gateway data plane..."
  wait_ready "$EG_NS" 5m || warn "sr-gateway's proxy Deployment did not become Available. Check: kubectl -n $AIGW_NS logs deploy/ai-gateway-controller"
fi

cat <<EOF

== Done

Reach the router (no TLS on this path -- put your own ingress in front of it
before exposing it anywhere):

  kubectl port-forward -n $EG_NS svc/sr-gateway 8080:8080

  curl -sS localhost:8080/v1/chat/completions \\
    -H "Authorization: Bearer \$YOUR_KEY" \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"auto","messages":[{"role":"user","content":"hello"}]}'

Without the Authorization header the same request must return 401.

Dashboard:

  kubectl port-forward -n $NAMESPACE svc/semantic-router-dashboard 8700:8700

Verify quota is actually charging tokens before relying on it -- see
README.md's verification section.
EOF
