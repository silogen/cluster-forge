#!/usr/bin/env bash
# Install the byok minimal core on a Spur k0s cluster that already exists.
# Run it on a node of the Spur cluster. See byok/README.md, section Spur k0s.
set -euo pipefail

REF="${REF:-main}"
SOURCE=""
PROFILE="profiles/scalable-inference.yaml"
SMOKE=no
REPO="${CLUSTER_FORGE_REPO:-https://github.com/silogen/cluster-forge.git}"
CHECKOUT_DIR="${CHECKOUT_DIR:-$HOME/cluster-forge}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/byok-admin.yaml}"
HELM_VERSION="${HELM_VERSION:-}"
KUBECTL_VERSION="${KUBECTL_VERSION:-}"
YQ_VERSION="${YQ_VERSION:-latest}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[$(date -u +%H:%M:%S)] $*"; }

usage() {
  cat <<'EOF'
Usage:
  install.sh [--ref <git ref>] [--source <path>] [--profile <file>] [--smoke]

Run on a node of a Spur k0s cluster. The script installs helm, kubectl, yq and
jq when they are missing, gets the cluster-admin kubeconfig from Spur, clones
cluster-forge at --ref, and runs byok/bootstrap.sh install.

Options:
  --ref <git ref>   cluster-forge tag or branch to clone. Default: main.
  --source <path>   Use this cluster-forge checkout instead of a clone.
  --profile <file>  Profile file, relative to byok/ or absolute.
                    Default: profiles/scalable-inference.yaml.
  --smoke           Run byok/tests/smoke.sh after the install.

Environment:
  CLUSTER_FORGE_REPO  Clone URL. Default: https://github.com/silogen/cluster-forge.git
  CHECKOUT_DIR        Clone target. Default: $HOME/cluster-forge
  KUBECONFIG_OUT      Where the admin kubeconfig is written.
                      Default: $HOME/.kube/byok-admin.yaml
  HELM_VERSION        Helm version to install, for example v3.19.0. Default: latest 3.x.
  KUBECTL_VERSION     kubectl version to install, for example v1.36.0. Default: latest stable.
  YQ_VERSION          yq version to install, for example v4.52.5. Default: latest.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2;;
    --source) SOURCE="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --smoke) SMOKE=yes; shift;;
    -h|--help) usage; exit 0;;
    *) usage; die "unknown argument: $1";;
  esac
done

arch="$(uname -m)"
case "$arch" in
  x86_64) arch=amd64;;
  aarch64) arch=arm64;;
  *) die "unsupported architecture: $arch";;
esac

install_tools() {
  local tmp="$WORK_DIR"
  if ! command -v jq >/dev/null; then
    info "install jq"
    sudo apt-get install -y -q jq >/dev/null
  fi
  if ! command -v helm >/dev/null; then
    info "install helm ${HELM_VERSION:-latest}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$tmp/get-helm-3"
    if [ -n "$HELM_VERSION" ]; then
      bash "$tmp/get-helm-3" --version "$HELM_VERSION" >/dev/null
    else
      bash "$tmp/get-helm-3" >/dev/null
    fi
  fi
  if ! command -v kubectl >/dev/null; then
    local kv="$KUBECTL_VERSION"
    [ -n "$kv" ] || kv="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    info "install kubectl $kv"
    curl -fsSL "https://dl.k8s.io/release/$kv/bin/linux/$arch/kubectl" -o "$tmp/kubectl"
    sudo install -m 755 "$tmp/kubectl" /usr/local/bin/kubectl
  fi
  if ! command -v yq >/dev/null; then
    info "install yq $YQ_VERSION"
    local url
    if [ "$YQ_VERSION" = latest ]; then
      url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$arch"
    else
      url="https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$arch"
    fi
    curl -fsSL "$url" -o "$tmp/yq"
    sudo install -m 755 "$tmp/yq" /usr/local/bin/yq
  fi
  command -v git >/dev/null || { info "install git"; sudo apt-get install -y -q git >/dev/null; }
}

# Spur serves the admin kubeconfig over RPC when [cluster] allow_admin_kubeconfig
# is true. On the control-plane node k0s gives it directly.
# shellcheck disable=SC2024  # the file must belong to the caller, not to root
fetch_kubeconfig() {
  mkdir -p "$(dirname "$KUBECONFIG_OUT")"
  local ok=no
  if command -v spur >/dev/null && sudo spur k8s kubeconfig --admin > "$KUBECONFIG_OUT.tmp" 2>/dev/null \
      && grep -q 'server:' "$KUBECONFIG_OUT.tmp"; then
    info "admin kubeconfig from spur k8s kubeconfig --admin"
    ok=yes
  elif command -v k0s >/dev/null && sudo k0s kubeconfig admin > "$KUBECONFIG_OUT.tmp" 2>/dev/null \
      && grep -q 'server:' "$KUBECONFIG_OUT.tmp"; then
    info "admin kubeconfig from k0s kubeconfig admin"
    ok=yes
  fi
  if [ "$ok" = no ]; then
    rm -f "$KUBECONFIG_OUT.tmp"
    die "cannot get the admin kubeconfig. Set [cluster] allow_admin_kubeconfig = true in spur.conf, or run this on the control-plane node."
  fi
  mv "$KUBECONFIG_OUT.tmp" "$KUBECONFIG_OUT"
  chmod 600 "$KUBECONFIG_OUT"
  export KUBECONFIG="$KUBECONFIG_OUT"
  kubectl get nodes >/dev/null || die "the kubeconfig does not reach the cluster"
}

resolve_source() {
  if [ -n "$SOURCE" ]; then
    [ -f "$SOURCE/byok/bootstrap.sh" ] || die "$SOURCE is not a cluster-forge checkout"
    return
  fi
  if [ -d "$CHECKOUT_DIR/.git" ]; then
    info "update $CHECKOUT_DIR to $REF"
    git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$REF" >/dev/null 2>&1 \
      || die "cannot fetch ref $REF from $REPO"
    git -C "$CHECKOUT_DIR" checkout -q --detach FETCH_HEAD
  else
    info "clone $REPO at $REF into $CHECKOUT_DIR"
    git clone --depth 1 --branch "$REF" "$REPO" "$CHECKOUT_DIR" >/dev/null 2>&1 \
      || die "cannot clone $REPO at ref $REF"
  fi
  SOURCE="$CHECKOUT_DIR"
}

main() {
  install_tools
  fetch_kubeconfig
  resolve_source
  local profile="$PROFILE"
  [ -f "$profile" ] || profile="$SOURCE/byok/$PROFILE"
  [ -f "$profile" ] || die "no such profile: $PROFILE"

  info "install profile $(basename "$profile") from $SOURCE"
  "$SOURCE/byok/bootstrap.sh" install --profile "$profile"

  if [ "$SMOKE" = yes ]; then
    info "run the smoke test"
    "$SOURCE/byok/tests/smoke.sh"
  fi
  echo
  echo "Done. Use the cluster with:"
  echo "  export KUBECONFIG=$KUBECONFIG_OUT"
}

main
