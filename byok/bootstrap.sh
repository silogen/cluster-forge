#!/usr/bin/env bash
# Install, validate or remove byok packages on a Kubernetes cluster that
# already exists. See README.md.
set -euo pipefail

BYOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
WORK_DIR="$(mktemp -d)"
declare -A VAR_OVERRIDE=()
declare -A VAR_VALUE=()
READY_PROFILE=""
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[$(date -u +%H:%M:%S)] $*"; }

usage() {
  cat <<'EOF'
Usage:
  bootstrap.sh install  --profile <file> [--var name=value]... [--source github:<ref> | --source <path>]
  bootstrap.sh validate --profile <file> [--var name=value]...
  bootstrap.sh remove   <package> [--purge]

Options:
  --var name=value  Fill a variable that the profile declares under vars.
                    Repeat it for every variable. A declared variable with an
                    empty value stops the run.

Environment:
  KUBECONFIG    Path to the cluster-admin kubeconfig. Required.
  HELM_TIMEOUT  Helm --timeout value. Default 10m.
EOF
}

check_tools() {
  for t in helm kubectl yq jq git; do
    command -v "$t" >/dev/null || die "$t is not on PATH"
  done
  local hv
  hv="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')"
  [ -n "$hv" ] || die "cannot read the helm version"
  local major="${hv%%.*}" rest="${hv#*.}" minor
  minor="${rest%%.*}"
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 8 ]; }; then
    die "helm 3.8 or later is needed, found $hv"
  fi
  yq --version 2>/dev/null | grep -q 'version v4' || die "yq v4 is needed"
}

check_admin() {
  [ -n "${KUBECONFIG:-}" ] || die "KUBECONFIG is not set"
  kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
    || die "the KUBECONFIG identity is not cluster-admin"
}

# Sets BYOK_DIR to a checkout of the wanted source.
resolve_source() {
  local src="$1"
  [ -n "$src" ] || return 0
  case "$src" in
    github:*)
      local ref="${src#github:}"
      info "clone cluster-forge at $ref"
      git clone --depth 1 --branch "$ref" \
        https://github.com/silogen/cluster-forge.git "$WORK_DIR/cluster-forge" >/dev/null 2>&1 \
        || die "cannot clone cluster-forge at ref $ref"
      BYOK_DIR="$WORK_DIR/cluster-forge/byok"
      ;;
    *)
      [ -d "$src/byok" ] && BYOK_DIR="$src/byok" || BYOK_DIR="$src"
      ;;
  esac
  [ -d "$BYOK_DIR/packages" ] || die "no packages directory under $BYOK_DIR"
}

# Resolves extends and fills the vars. Sets READY_PROFILE.
# The base packages come first. A child entry with the same name replaces the
# base entry in place. Child-only entries follow in child order.
prepare_profile() { # <profile file>
  local profile="$1" base merged="$WORK_DIR/profile-merged.yaml"
  READY_PROFILE="$WORK_DIR/profile.yaml"
  base="$(yq -r '.extends // ""' "$profile")"
  if [ -n "$base" ]; then
    local base_file="$(dirname "$profile")/$base.yaml"
    [ -f "$base_file" ] || die "profile $(basename "$profile") extends $base, but $base_file does not exist"
    [ -z "$(yq -r '.extends // ""' "$base_file")" ] \
      || die "profile $base itself extends another profile, one level only"
    BASE="$base_file" CHILD="$profile" yq -n '
      load(strenv(BASE)) as $b | load(strenv(CHILD)) as $c |
      ($b * $c) * {"packages":
        (($b.packages // []) | map(. as $bp | (($c.packages // []) | map(select(.name == $bp.name)) | .[0]) // $bp))
        + (($c.packages // []) | map(select([.name] - ($b.packages // [] | map(.name)) | length > 0)))
      }' > "$merged"
  else
    cp "$profile" "$merged"
  fi
  substitute_vars "$merged" "$READY_PROFILE"
}

# Replaces ${name} with the value of every declared var. VAR_OVERRIDE holds
# the --var values.
substitute_vars() { # <in> <out>
  local in="$1" out="$2" name value text left
  text="$(<"$in")"
  for name in $(yq -r '.vars // {} | keys | .[]' "$in"); do
    if [ -n "${VAR_OVERRIDE[$name]+set}" ]; then
      value="${VAR_OVERRIDE[$name]}"
    else
      value="$(NAME="$name" yq -r '.vars[strenv(NAME)] // ""' "$in")"
    fi
    [ -n "$value" ] || die "the profile needs --var $name=<value>"
    VAR_VALUE[$name]="$value"
    text="${text//\$\{$name\}/$value}"
  done
  for name in "${!VAR_OVERRIDE[@]}"; do
    [ -n "${VAR_VALUE[$name]+set}" ] || die "the profile does not declare the variable $name"
  done
  left="$(printf '%s' "$text" | grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' | sort -u | tr '\n' ' ' || true)"
  [ -z "$left" ] || die "the profile uses variables that it does not declare: $left"
  printf '%s\n' "$text" > "$out"
}

print_notes() { # <ready profile>
  local notes
  notes="$(yq -r '.notes // ""' "$1")"
  [ -n "$notes" ] || return 0
  echo
  printf '%s\n' "$notes"
}

pkg_field() { yq -r "$2" "$BYOK_DIR/packages/$1/package.yaml"; }

profile_packages() { yq -r '.packages[].name' "$1"; }

probe_capability() {
  local cap="$1" probe
  probe="$(CAP="$cap" yq -r '.[strenv(CAP)].probe // ""' "$BYOK_DIR/capabilities.yaml")"
  [ -n "$probe" ] || return 1
  bash -c "$probe" >/dev/null 2>&1
}

providers_of() {
  local cap="$1" p
  for p in "$BYOK_DIR"/packages/*/package.yaml; do
    CAP="$cap" yq -e '.provides // [] | any_c(. == strenv(CAP))' "$p" >/dev/null 2>&1 \
      && basename "$(dirname "$p")"
  done
}

validate_profile() {
  local profile="$1" seen="" pkg cap ok
  for pkg in $(profile_packages "$profile"); do
    [ -f "$BYOK_DIR/packages/$pkg/package.yaml" ] || die "unknown package: $pkg"
    for cap in $(pkg_field "$pkg" '.requires // [] | .[]'); do
      ok=no
      case " $seen " in *" $cap "*) ok=yes;; esac
      [ "$ok" = no ] && probe_capability "$cap" && ok=yes
      if [ "$ok" = no ]; then
        echo "error: package $pkg needs capability $cap" >&2
        echo "  no earlier package in the profile provides it and the cluster probe failed" >&2
        echo "  packages that provide it: $(providers_of "$cap" | tr '\n' ' ')" >&2
        exit 1
      fi
    done
    seen="$seen $(pkg_field "$pkg" '.provides // [] | .[]' | tr '\n' ' ')"
  done
  info "validation passed for $(basename "$profile")"
}

# A chart that holds both a webhook and objects that the webhook validates
# fails on the first pass, because the webhook server starts later. ArgoCD
# retries such a sync; helm does not, so retry here.
helm_install_retry() { # <name> <dir> <namespace> <profile values file>
  local pkg="$1" dir="$2" ns="$3" vals="$4" try
  for try in 1 2 3; do
    if helm upgrade --install "$pkg" "$dir" \
        --namespace "$ns" --create-namespace \
        --values "$dir/values.yaml" --values "$vals" \
        --wait --timeout "$HELM_TIMEOUT"; then
      return 0
    fi
    [ "$try" -eq 3 ] && die "install of $pkg failed after 3 attempts"
    # A first install that fails leaves a release that upgrade cannot use.
    if [ "$(helm status "$pkg" --namespace "$ns" -o json 2>/dev/null \
            | jq -r '.version // 0')" = 1 ]; then
      helm uninstall "$pkg" --namespace "$ns" --wait >/dev/null 2>&1 || true
    fi
    info "attempt $try for $pkg failed, wait 20s and try again"
    sleep 20
  done
}

install_profile() {
  local profile="$1" pkg ns dir vals
  validate_profile "$profile"
  for pkg in $(profile_packages "$profile"); do
    dir="$BYOK_DIR/packages/$pkg"
    ns="$(pkg_field "$pkg" '.namespace')"
    info "build dependencies for $pkg"
    helm dependency build "$dir" >/dev/null
    vals="$WORK_DIR/values-$pkg.yaml"
    PKG="$pkg" yq -r '.packages[] | select(.name == strenv(PKG)) | .values // {}' "$profile" > "$vals"
    info "install $pkg into namespace $ns"
    helm_install_retry "$pkg" "$dir" "$ns" "$vals"
  done
  print_notes "$profile"
  info "install finished"
}

remove_package() {
  local pkg="$1" purge="$2" ns other cap
  [ -f "$BYOK_DIR/packages/$pkg/package.yaml" ] || die "unknown package: $pkg"
  ns="$(pkg_field "$pkg" '.namespace')"

  # Refuse when another installed release still needs what this package gives.
  for cap in $(pkg_field "$pkg" '.provides // [] | .[]'); do
    for other in "$BYOK_DIR"/packages/*/package.yaml; do
      local name; name="$(basename "$(dirname "$other")")"
      [ "$name" = "$pkg" ] && continue
      CAP="$cap" yq -e '.requires // [] | any_c(. == strenv(CAP))' "$other" >/dev/null 2>&1 || continue
      helm status "$name" --namespace "$(yq -r '.namespace' "$other")" >/dev/null 2>&1 \
        && die "$name is installed and needs $cap from $pkg"
    done
  done

  local crds=""
  if [ "$purge" = yes ]; then
    crds="$(helm get manifest "$pkg" --namespace "$ns" 2>/dev/null \
      | yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' || true)"
  fi

  info "uninstall $pkg from namespace $ns"
  helm uninstall "$pkg" --namespace "$ns" --wait --timeout "$HELM_TIMEOUT"

  if [ "$purge" = yes ]; then
    [ -n "$crds" ] && echo "$crds" | xargs -r kubectl delete crd --ignore-not-found
    kubectl delete pvc --all --namespace "$ns" --ignore-not-found
    kubectl delete namespace "$ns" --ignore-not-found
  fi
  info "remove finished"
}

main() {
  local cmd="${1:-}"; shift || true
  local profile="" source="" purge=no target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile="$2"; shift 2;;
      --var)
        case "$2" in *=*) :;; *) die "--var needs name=value, got $2";; esac
        VAR_OVERRIDE["${2%%=*}"]="${2#*=}"; shift 2;;
      --source) source="$2"; shift 2;;
      --purge) purge=yes; shift;;
      -h|--help) usage; exit 0;;
      -*) die "unknown flag: $1";;
      *) target="$1"; shift;;
    esac
  done

  case "$cmd" in
    install|validate)
      [ -n "$profile" ] || { usage; die "--profile is needed"; }
      check_tools; check_admin; resolve_source "$source"
      [ -f "$profile" ] || profile="$BYOK_DIR/$profile"
      [ -f "$profile" ] || die "no such profile file"
      prepare_profile "$profile"
      profile="$READY_PROFILE"
      if [ "$cmd" = install ]; then install_profile "$profile"; else validate_profile "$profile"; fi
      ;;
    remove)
      [ -n "$target" ] || { usage; die "a package name is needed"; }
      check_tools; check_admin
      remove_package "$target" "$purge"
      ;;
    ""|-h|--help) usage;;
    *) usage; die "unknown command: $cmd";;
  esac
}

main "$@"
