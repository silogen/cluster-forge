#!/bin/bash

set -euo pipefail

#
#
# # # UPDATE ON RELEASES # # #
#
LATEST_RELEASE="v2.0.2"
#
#
#
#

CLEANUP_DIRS=()
cleanup() {
  for dir in "${CLEANUP_DIRS[@]:-}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

# Initialize variables
APPS=""
AIWB_ONLY=false
CLUSTER_SIZE="medium"  # Default to medium
DISABLED_APPS=""
DEFAULT_TIMEOUT="5m"
DOMAIN=""
KUBE_VERSION=1.33
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_DEPENDENCY_CHECK=false
TARGET_REVISION="$LATEST_RELEASE"
TEMPLATE_ONLY=false
VALUES_FILE="values.yaml"

# Helper function to print messages only when not in template mode
log_info() {
  if [ "$TEMPLATE_ONLY" = false ]; then
    echo "$@"
  fi
}



# Generate a secure random password
generate_password() {
  openssl rand -hex 16
}

# Generate enabledApps section with disabled apps commented out
generate_enabled_apps_yaml() {
  local values_file="$1"
  local disabled_apps="$2"
  
  # Extract enabledApps list and generate YAML with commented disabled apps
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    if [ -n "$disabled_apps" ] && is_disabled_app "$app"; then
      echo "    #- $app                    # Disabled by --disabled-apps"
    else
      echo "    - $app"
    fi
  done < <(yq eval '.enabledApps[]' "$values_file" 2>/dev/null || true)
}

# Check for required dependencies
check_dependencies() {
  local silent="${1:-false}"
  local missing_deps=()
  local all_good=true
  
  if [ "$silent" != "true" ]; then
    echo "=== Checking Dependencies ==="
  fi
  
  # Define required programs with installation instructions
  declare -A REQUIRED_PROGRAMS=(
    ["kubectl"]="Kubernetes CLI - https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    ["helm"]="Helm package manager - https://helm.sh/docs/intro/install/"
    ["yq"]="YAML/JSON processor - https://github.com/mikefarah/yq#install"
    ["openssl"]="OpenSSL for password generation - Usually pre-installed or via package manager"
  )
  
  # Define optional programs (used by shell builtins but good to check)
  declare -A OPTIONAL_PROGRAMS=(
    ["cat"]="cat command - Usually pre-installed"
    ["grep"]="grep command - Usually pre-installed" 
    ["tr"]="tr command - Usually pre-installed"
    ["head"]="head command - Usually pre-installed"
  )
  
  # Check required programs with version info
  for program in "${!REQUIRED_PROGRAMS[@]}"; do
    if command -v "$program" >/dev/null 2>&1; then
      case "$program" in
        "kubectl")
          version=$(kubectl version --client 2>/dev/null | head -n1 | cut -d' ' -f3 2>/dev/null || echo "unknown")
          [ "$silent" != "true" ] && printf "  ✓ %-12s %s (%s)\n" "$program" "$(command -v "$program")" "$version"
          ;;
        "helm")
          version=$(helm version --short --client 2>/dev/null | cut -d'+' -f1 2>/dev/null || echo "unknown")
          [ "$silent" != "true" ] && printf "  ✓ %-12s %s (%s)\n" "$program" "$(command -v "$program")" "$version"
          ;;
        "yq")
          version=$(yq --version 2>/dev/null | head -n1 | cut -d' ' -f4 2>/dev/null || echo "unknown")
          [ "$silent" != "true" ] && printf "  ✓ %-12s %s (%s)\n" "$program" "$(command -v "$program")" "$version"
          ;;
        *)
          [ "$silent" != "true" ] && printf "  ✓ %-12s %s\n" "$program" "$(command -v "$program")"
          ;;
      esac
    else
      [ "$silent" != "true" ] && printf "  ✗ %-12s MISSING\n" "$program"
      missing_deps+=("$program")
      all_good=false
    fi
  done
  
  # Check optional programs (warn but don't fail)
  for program in "${!OPTIONAL_PROGRAMS[@]}"; do
    if command -v "$program" >/dev/null 2>&1; then
      [ "$silent" != "true" ] && printf "  ✓ %-12s %s\n" "$program" "$(command -v "$program")"
    else
      [ "$silent" != "true" ] && printf "  ! %-12s MISSING (usually pre-installed)\n" "$program"
    fi
  done
  
  # If any required dependencies are missing, show installation instructions
  if [ "$all_good" = false ]; then
    echo ""
    echo "ERROR: Missing required dependencies!"
    echo ""
    echo "Please install the following programs:"
    echo ""
    
    for dep in "${missing_deps[@]}"; do
      echo "  $dep: ${REQUIRED_PROGRAMS[$dep]}"
      echo ""
      
      # Provide platform-specific installation hints
      case "$dep" in
        "kubectl")
          echo "    # Linux:"
          echo "    curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
          echo "    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
          echo ""
          echo "    # macOS:"
          echo "    brew install kubectl"
          echo ""
          echo "    # Or download from: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
          ;;
        "helm")
          echo "    # Linux/macOS:"
          echo "    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
          echo ""
          echo "    # Or via package manager:"
          echo "    # Linux: snap install helm --classic"
          echo "    # macOS: brew install helm"
          ;;
        "yq")
          echo "    # Linux:"
          echo "    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
          echo "    sudo chmod +x /usr/local/bin/yq"
          echo ""
          echo "    # macOS:"
          echo "    brew install yq"
          ;;
        "openssl")
          echo "    # Linux:"
          echo "    # Ubuntu/Debian: sudo apt-get install openssl"
          echo "    # RHEL/CentOS: sudo yum install openssl"
          echo ""
          echo "    # macOS: Usually pre-installed, or: brew install openssl"
          ;;
      esac
      echo ""
    done
    
    echo "After installing the missing dependencies, please run this script again."
    exit 1
  fi
  
  if [ "$silent" != "true" ]; then
    echo "  ✓ All required dependencies are available!"
    echo ""
  fi
}

parse_args() {
  # Parse arguments 
  while [[ $# -gt 0 ]]; do
    case $1 in
      --CLUSTER-SIZE|--cluster-size|-s)
          if [ -z "$2" ]; then
            echo "ERROR: --cluster-size requires an argument"
            exit 1
          fi
          CLUSTER_SIZE="$2"
          shift 2
          ;;
        --CLUSTER-SIZE=*)
          CLUSTER_SIZE="${1#*=}"
          shift
          ;;
        --cluster-size=*)
          CLUSTER_SIZE="${1#*=}"
          shift
          ;;
        -s=*)
          CLUSTER_SIZE="${1#*=}"
          shift
          ;;
        --CLUSTER_SIZE)
          if [ -z "$2" ]; then
            echo "ERROR: --CLUSTER_SIZE requires an argument"
            exit 1
          fi
          CLUSTER_SIZE="$2"
          shift 2
          ;;
        --CLUSTER_SIZE=*)
          CLUSTER_SIZE="${1#*=}"
          shift
          ;;
        --TARGET-REVISION|--target-revision|-r)
          if [ -z "$2" ]; then
            echo "WARNING: defaulting to --target-revision=$LATEST_RELEASE (no value specified)"
            TARGET_REVISION="$LATEST_RELEASE"
            shift
          else
            TARGET_REVISION="$2"
            shift 2
          fi
          ;;
        --TARGET-REVISION=*)
          TARGET_REVISION="${1#*=}"
          shift
          ;;
        --target-revision=*)
          TARGET_REVISION="${1#*=}"
          shift
          ;;
        -r=*)
          TARGET_REVISION="${1#*=}"
          shift
          ;;
        --template-only|-t)
          TEMPLATE_ONLY=true
          shift
          ;;
        --skip-deps)
          SKIP_DEPENDENCY_CHECK=true
          shift
          ;;
        --apps=*)
          APPS="${1#*=}"
          shift
          ;;
        --disabled-apps)
          if [ -z "$2" ]; then
            echo "ERROR: --disabled-apps requires an argument"
            exit 1
          fi
          DISABLED_APPS="$2"
          shift 2
          ;;
        --disabled-apps=*)
          DISABLED_APPS="${1#*=}"
          shift
          ;;
        --aiwb-only)
          AIWB_ONLY=true
          shift
          ;;
        --aiwb-only=true)
          AIWB_ONLY=true
          shift
          ;;
        --aiwb-only=false)
          AIWB_ONLY=false
          shift
          ;;
        --airm-image-repository)
          if [ -z "$2" ]; then
            echo "ERROR: --airm-image-repository requires an argument"
            exit 1
          fi
          AIRM_IMAGE_REPOSITORY="$2"
          shift 2
          ;;
        --airm-image-repository=*)
          AIRM_IMAGE_REPOSITORY="${1#*=}"
          shift
          ;;
      --help|-h)
        cat <<HELP_OUTPUT
        Usage: $0 [options] <domain> [values_file]
  
        Arguments:
          domain                             REQUIRED. Cluster domain (e.g., myIp.nip.io)
          values_file                        Optional. Values .yaml file to use, default: root/values.yaml
        
        Options:
          --aiwb-only                        Deploy only AIWB components; implicitly sets --disabled-apps=airm,airm-*,kaiwo,kaiwo-*
                                             and passes aiwbOnly=true to the gitea-init job. User-supplied --disabled-apps are appended.
          --airm-image-repository=url        Custom AIRM image repository for gitea-init job (e.g., ghcr.io/silogen, requires regcreds)
          --apps=app1[,app2,...]             Deploy (kubectl apply) specified components onlye
                                             options: namespaces, argocd, openbao, gitea, cluster-forge, or any cluster-forge child app (see values.yaml for app names)
          --disabled-apps=app1[,app2,glob*]  Exclude specified apps from installation. Supports * and ? wildcards.
                                             Example: --disabled-apps=airm,airm-infra-* skips airm, airm-infra-cnpg, airm-infra-external-secrets, etc.
                                             
          --cluster-size=[size],      -s     [size] can be one of small|medium|large|openshift, default: medium
          --help,                     -h     Show this help message and exit
          --skip-deps                        Skip dependency checking (not recommended)
          --target-revision,          -r     Git revision for ArgoCD to sync from, [tag|commit_hash|branch_name], default: $LATEST_RELEASE
          --template-only,            -t     Output YAML manifests to stdout instead of applying to cluster
        
        
        Examples:
          $0 compute.amd.com values_custom.yaml --cluster-size=large
          $0 112.100.97.17.nip.io
          $0 dev.example.com --cluster-size=small --target-revision=v2.0.2
          $0 dev.example.com -s=small -r=feature-branch
          $0 example.com --apps=openbao
          $0 example.com --apps=keycloak -t
          $0 example.com --disabled-apps=airm,airm-infra-*
          $0 example.com --apps=airm,keycloak --disabled-apps=airm
          $0 example.com --aiwb-only
          $0 example.com --aiwb-only --disabled-apps=extra-app
          $0 example.com --cluster-size=openshift
          
        Bootstrap Behavior:
          • deploys ArgoCD + OpenBao + Gitea directly (essential infrastructure)
          • apply the cluster-forge application manifest (parent app only)
          • ArgoCD syncs remaining apps from specified target revision, respecting syncWaves and dependencies
          • --disabled-apps patterns are removed from enabledApps before pushing to Gitea, so ArgoCD never deploys them
          • if an app appears in both --apps and --disabled-apps, it is skipped (disabled takes priority)
          • --aiwb-only implicitly disables airm,airm-*,kaiwo,kaiwo-* (appended to any --disabled-apps)
HELP_OUTPUT
        exit 0
        ;;
      --*)
        echo "ERROR: Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
      *)
        # Positional arguments
        if [ -z "$DOMAIN" ]; then
          DOMAIN="$1"
        elif [ "$VALUES_FILE" = "values.yaml" ]; then
          VALUES_FILE="$1"
        else
          echo "ERROR: Too many arguments: $1"
          echo "Usage: $0 [--CLUSTER_SIZE=small|medium|large] [--dev] <domain> [values_file]"
          exit 1
        fi
        shift
        ;;
    esac
  done
}

validate_args() {
  # Validate required arguments
  if [ -z "$DOMAIN" ]; then
      echo "ERROR: Domain argument is required"
      echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large|openshift]"
      echo "Use --help for more details"
      exit 1
  fi
  
  # Validate cluster size
  case "$CLUSTER_SIZE" in
    small|medium|large|openshift)
      ;;
    *)
      echo "ERROR: Invalid cluster size '$CLUSTER_SIZE'"
      echo "Valid sizes: small, medium, large, openshift"
      exit 1
      ;;
  esac
  
  # Validate values file exists
  if [ ! -f "${SCRIPT_DIR}/../root/${VALUES_FILE}" ]; then
      echo "ERROR: Values file not found: ${SCRIPT_DIR}/../root/${VALUES_FILE}"
      exit 1
  fi
  
  SOURCE_ROOT="${SCRIPT_DIR}/.."
  setup_values_files
}

# Check if size-specific values file exists - matching main approach
setup_values_files() {
    SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
    
    if [ ! -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
        log_info "WARNING: Size-specific values file not found: ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}"
        log_info "Proceeding with base values file only: ${VALUES_FILE}"
        SIZE_VALUES_FILE=""
    else
        log_info "Using size-specific values file: ${SIZE_VALUES_FILE}"
    fi
}

print_summary() {
  # Don't print summary if just outputting templates
  # if [ "$TEMPLATE_ONLY" = true ]; then
  #   return
  # fi

  cat <<SUMMARY_OUTPUT
  === ClusterForge Bootstrap ===
  Domain: $DOMAIN
  Base values: $VALUES_FILE
  Cluster size: $CLUSTER_SIZE
  Target revision: $TARGET_REVISION

SUMMARY_OUTPUT
}

# Returns 0 if the given app should be run (no filter set, or app is in APPS list)
should_run() {
  local app="$1"
  [ -z "$APPS" ] && return 0
  echo ",${APPS}," | grep -q ",${app},"
}

# Returns 0 if the app matches any pattern in DISABLED_APPS (supports * and ? glob wildcards)
is_disabled_app() {
  local app="$1"
  [ -z "$DISABLED_APPS" ] && return 1

  local IFS=','
  local pattern
  for pattern in $DISABLED_APPS; do
    # shellcheck disable=SC2254
    case "$app" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# Helper function to either apply directly or output YAML for templating
apply_or_template() {
  if [ "$TEMPLATE_ONLY" = true ]; then
    cat
  else
    kubectl apply "$@"
  fi
}

# Create namespaces
create_namespaces() {
  for ns in argocd cf-gitea cf-openbao; do
    kubectl create ns "$ns" --dry-run=client -o yaml | apply_or_template -f -
  done
}

# Extract ArgoCD values using yq
extract_argocd_values() {
  ARGOCD_TEMP_DIR=$(mktemp -d -t cf-argocd-bootstrap.XXXXXX) || { log_info "ERROR: Cannot create temp directory"; exit 1; }
  CLEANUP_DIRS+=("${ARGOCD_TEMP_DIR}")
  # Create temporary values file for ArgoCD bootstrap
  cat > "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values.yaml" << EOF
global:
  domain: argocd.${DOMAIN}
EOF
  
  # Extract and merge ArgoCD values from the apps structure
  yq eval '.apps.argocd.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" >> "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values.yaml"
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    if yq eval '.apps.argocd.valuesObject // ""' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | grep -q .; then
      yq eval '.apps.argocd.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values.yaml" - > "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values_merged.yaml"
      mv "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values_merged.yaml" "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values.yaml"
    fi
  fi
}

# ArgoCD bootstrap
bootstrap_argocd() {
  log_info "=== ArgoCD Bootstrap ==="
  extract_argocd_values
  helm template --release-name argocd ${SOURCE_ROOT}/sources/argocd/8.3.5 --namespace argocd \
    --values "${ARGOCD_TEMP_DIR}/argocd_bootstrap_values.yaml" \
    --kube-version=${KUBE_VERSION} | apply_or_template --server-side --field-manager=argocd-controller --force-conflicts -f -
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-redis -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-repo-server -n argocd --timeout="${DEFAULT_TIMEOUT}"
  fi
  rm -rf "${ARGOCD_TEMP_DIR}"
}



bootstrap_openbao() {
  log_info "=== OpenBao Bootstrap ==="
  
  log_info "Debug: SOURCE_ROOT='${SOURCE_ROOT}'"
  log_info "Debug: VALUES_FILE='${VALUES_FILE}'"
  log_info "Debug: SIZE_VALUES_FILE='${SIZE_VALUES_FILE}'"
  log_info "Debug: CLUSTER_SIZE='${CLUSTER_SIZE}'"
  
  # Get OpenBao version from app path - using same method as main
  OPENBAO_VERSION=$(yq eval '.apps.openbao.path' "${SOURCE_ROOT}/root/${VALUES_FILE}" | cut -d'/' -f2)
  log_info "OpenBao version: $OPENBAO_VERSION"

  # Create a temporary directory for processing OpenBao values
  TEMP_DIR=$(mktemp -d -t cf-bootstrap.XXXXXX) || { log_info "ERROR: Cannot create temp directory"; exit 1; }
  CLEANUP_DIRS+=("${TEMP_DIR}")
  log_info "Using temp directory: $TEMP_DIR"

  # Extract OpenBao values from base configuration
  log_info "Extracting OpenBao values..."
  yq eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > "${TEMP_DIR}/openbao_values.yaml" || { echo "ERROR: Failed to extract OpenBao values from ${VALUES_FILE}"; exit 1; }
  
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    log_info "Extracting OpenBao size-specific values from ${SIZE_VALUES_FILE}..."
    log_info "Checking if openbao section exists in size values file..."
    if yq eval 'has("apps") and .apps.openbao' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | grep -q true; then
      log_info "OpenBao section found, extracting values..."
      if ! yq eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > "${TEMP_DIR}/openbao_size_values.yaml"; then
        log_info "WARNING: Failed to extract OpenBao valuesObject from ${SIZE_VALUES_FILE}, using empty values"
        printf "# OpenBao valuesObject not found in size file\n" > "${TEMP_DIR}/openbao_size_values.yaml"
      fi
    else
      log_info "No OpenBao section in size values file, creating empty placeholder..."
      printf "# No OpenBao section in size-specific values\n" > "${TEMP_DIR}/openbao_size_values.yaml"
    fi
  else
    log_info "No size-specific values file, creating empty placeholder..."
    printf "# No size-specific values\n" > "${TEMP_DIR}/openbao_size_values.yaml"
  fi
  
  # Use server-side apply to match ArgoCD's field management strategy
  helm template --release-name openbao ${SOURCE_ROOT}/sources/openbao/${OPENBAO_VERSION} --namespace cf-openbao \
    -f "${TEMP_DIR}/openbao_values.yaml" \
    -f "${TEMP_DIR}/openbao_size_values.yaml" \
    --set ui.enabled=true \
    --kube-version=${KUBE_VERSION} | apply_or_template --server-side --field-manager=argocd-controller --force-conflicts -f -
    
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
    
    # Create initial secrets config for init job (separate from ArgoCD-managed version)
    log_info "Creating initial OpenBao secrets configuration..."
    cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-manager-cm.yaml | \
      sed "s|name: openbao-secret-manager-scripts|name: openbao-secret-manager-scripts-init|g" | kubectl apply -f -
    
    # Create initial secrets config for init job (separate from ArgoCD-managed version)  
    cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | \
      sed "s|{{ .Values.domain }}|${DOMAIN}|g" | \
      sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -
    
    # Pass OpenBao configuration to init script
    helm template --release-name openbao-init ${SOURCE_ROOT}/scripts/init-openbao-job \
      -f "${TEMP_DIR}/openbao_values.yaml" \
      --set domain="${DOMAIN}" \
      --kube-version=${KUBE_VERSION} | kubectl apply -f -
    kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
  fi
  
  # Cleanup temp directory
  rm -rf "${TEMP_DIR}"
}



bootstrap_gitea() {
  log_info "=== Gitea Bootstrap ==="
  
  # Print debug information
  log_info "Debug: SOURCE_ROOT='${SOURCE_ROOT}'"
  log_info "Debug: VALUES_FILE='${VALUES_FILE}'"
  log_info "Debug: SIZE_VALUES_FILE='${SIZE_VALUES_FILE}'"
  log_info "Debug: CLUSTER_SIZE='${CLUSTER_SIZE}'"
  
  # Get Gitea version from app path - matching main approach
  GITEA_VERSION=$(yq eval '.apps.gitea.path' "${SOURCE_ROOT}/root/${VALUES_FILE}" | cut -d'/' -f2)
  log_info "Gitea version: $GITEA_VERSION"

  # Create a temporary directory for processing Gitea values
  TEMP_DIR=$(mktemp -d -t cf-gitea-bootstrap.XXXXXX) || { log_info "ERROR: Cannot create temp directory"; exit 1; }
  CLEANUP_DIRS+=("${TEMP_DIR}")
  log_info "Using temp directory: $TEMP_DIR"
  
  # Create initial-cf-values configmap (complete values for gitea-init-job)
  # Use the complete root values.yaml with filled placeholders instead of simplified version
  cp "${SOURCE_ROOT}/root/${VALUES_FILE}" "${TEMP_DIR}/complete_values.yaml"
  
  # Fill in placeholder values using yq (these are used by gitea-init job)
  yq eval ".global.domain = \"${DOMAIN}\"" -i "${TEMP_DIR}/complete_values.yaml"
  if [ -n "${SIZE_VALUES_FILE}" ]; then
    yq eval ".global.clusterSize = \"${SIZE_VALUES_FILE}\"" -i "${TEMP_DIR}/complete_values.yaml"
  else
    yq eval ".global.clusterSize = \"values_${CLUSTER_SIZE}.yaml\"" -i "${TEMP_DIR}/complete_values.yaml"
  fi
  yq eval ".clusterForge.targetRevision = \"${TARGET_REVISION}\"" -i "${TEMP_DIR}/complete_values.yaml"
  
  # Merge with size-specific values if they exist
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    log_info "Merging with size-specific values: ${SIZE_VALUES_FILE}"
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "${TEMP_DIR}/complete_values.yaml" "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > "${TEMP_DIR}/complete_values_merged.yaml"
    mv "${TEMP_DIR}/complete_values_merged.yaml" "${TEMP_DIR}/complete_values.yaml"
    log_info "Merged values enabledApps count: $(yq eval '.enabledApps | length' "${TEMP_DIR}/complete_values.yaml" 2>/dev/null || echo "0")"
  else
    log_info "No size-specific values file to merge"
  fi

  # Note: We no longer remove disabled apps here since the Gitea init job will handle 
  # commenting them out in the values.yaml file that gets pushed to the Gitea repository
  if [ -n "$DISABLED_APPS" ]; then
    log_info "Disabled apps will be commented out in Gitea values.yaml: $DISABLED_APPS"
  fi

  kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$(cat "${TEMP_DIR}/complete_values.yaml")" --dry-run=client -o yaml | apply_or_template -n cf-gitea -f -
  
  kubectl create secret generic gitea-admin-credentials \
    --namespace=cf-gitea \
    --from-literal=username=silogen-admin \
    --from-literal=password=$(generate_password) \
    --dry-run=client -o yaml | apply_or_template -f -
  
  # Extract Gitea values like main does
  log_info "Extracting Gitea values..."
  yq eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > "${TEMP_DIR}/gitea_values.yaml" || { log_info "ERROR: Failed to extract Gitea values from ${VALUES_FILE}"; exit 1; }
  
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    log_info "Extracting Gitea size-specific values from ${SIZE_VALUES_FILE}..."
    log_info "Checking if gitea section exists in size values file..."
    if yq eval '.apps.gitea' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" >/dev/null 2>&1 && [ "$(yq eval '.apps.gitea' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}")" != "null" ]; then
      log_info "Gitea section found, extracting values..."
      yq eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > "${TEMP_DIR}/gitea_size_values.yaml" || { 
        log_info "WARNING: Failed to extract Gitea valuesObject from ${SIZE_VALUES_FILE}, using empty values"
        printf "# Gitea valuesObject not found in size file\n" > "${TEMP_DIR}/gitea_size_values.yaml"
      }
    else
      log_info "No Gitea section in size values file, creating empty placeholder..."
      printf "# No Gitea section in size-specific values\n" > "${TEMP_DIR}/gitea_size_values.yaml"
    fi
  else
    log_info "No size-specific values file, creating empty placeholder..."
    printf "# No size-specific values\n" > "${TEMP_DIR}/gitea_size_values.yaml"
  fi
  
  # Bootstrap Gitea - matching main approach
  helm template --release-name gitea ${SOURCE_ROOT}/sources/gitea/${GITEA_VERSION} --namespace cf-gitea \
    -f "${TEMP_DIR}/gitea_values.yaml" \
    -f "${TEMP_DIR}/gitea_size_values.yaml" \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
    --kube-version=${KUBE_VERSION} | apply_or_template -f -
  
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl rollout status deploy/gitea -n cf-gitea --timeout="${DEFAULT_TIMEOUT}"
  fi
  
  # Gitea Init Job - preserve AIRM repository functionality
  local helm_args=(
    "--release-name" "gitea-init"
    "${SOURCE_ROOT}/scripts/init-gitea-job"
    "--set" "clusterSize=${SIZE_VALUES_FILE:-values_${CLUSTER_SIZE}.yaml}"
    "--set" "domain=${DOMAIN}"
    "--set" "targetRevision=${TARGET_REVISION}"
    "--kube-version=${KUBE_VERSION}"
  )

  # Only add airmImageRepository if AIRM_IMAGE_REPOSITORY is set and non-empty
  if [ -n "${AIRM_IMAGE_REPOSITORY:-}" ]; then
    helm_args+=("--set" "airmImageRepository=${AIRM_IMAGE_REPOSITORY}")
  fi

  # Pass aiwbOnly flag if set
  if [ "${AIWB_ONLY}" = true ]; then
    helm_args+=("--set" "aiwbOnly=true")
  fi
  
  # Create temporary values file for disabledApps if needed
  local temp_values_file=""
  if [ -n "${DISABLED_APPS:-}" ]; then
    temp_values_file=$(mktemp -t gitea-disabled-apps.XXXXXX)
    CLEANUP_DIRS+=("${temp_values_file}")
    cat > "${temp_values_file}" << EOF
disabledApps: "${DISABLED_APPS}"
EOF
    helm_args+=("--values" "${temp_values_file}")
  fi

  # Check if gitea-init-job already completed successfully
  local skip_job_wait=false
  if [ "$TEMPLATE_ONLY" = false ] && kubectl get job gitea-init-job -n cf-gitea >/dev/null 2>&1; then
    local existing_succeeded=$(kubectl get job gitea-init-job -n cf-gitea -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "$existing_succeeded" -gt 0 ]; then
      log_info "Gitea init job already completed successfully, skipping creation and wait"
      skip_job_wait=true
    else
      log_info "Existing gitea-init-job found but not completed, recreating..."
      kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found
      helm template "${helm_args[@]}" | apply_or_template -f -
    fi
  else
    helm template "${helm_args[@]}" | apply_or_template -f -
  fi
  
  if [ "$TEMPLATE_ONLY" = false ] && [ "$skip_job_wait" = false ]; then
    log_info "Waiting for Gitea init job to complete..."
    
    # Wait for job to finish (either Complete or Failed)
    local timeout_seconds=300  # 5 minutes
    local elapsed=0
    local sleep_interval=5
    
    # Hybrid approach: kubectl wait with early failure detection
    log_info "Monitoring job completion with early failure detection..."
    
    # Start kubectl wait in background for success detection
    kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea 2>/dev/null &
    local wait_pid=$!
    
    # Monitor for early failure indicators
    while kill -0 $wait_pid 2>/dev/null; do
      # Check for too many failed pods (early exit)
      local failed_pod_count=$(kubectl get pods -n cf-gitea -l job-name=gitea-init-job --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
      
      if [ "$failed_pod_count" -ge 3 ]; then
        # Kill the background wait and exit early
        kill $wait_pid 2>/dev/null || true
        wait $wait_pid 2>/dev/null || true
        
        log_info "ERROR: Gitea init job has $failed_pod_count failed attempts"
        log_info "This indicates a persistent failure. Exiting early instead of waiting for all retries."
        
        # Get the most recent failed pod logs
        local latest_failed_pod=$(kubectl get pods -n cf-gitea -l job-name=gitea-init-job --field-selector=status.phase=Failed --sort-by='.metadata.creationTimestamp' --no-headers -o custom-columns=":metadata.name" | tail -n1)
        
        if [ -n "$latest_failed_pod" ]; then
          log_info "Latest failed pod: $latest_failed_pod"
          log_info "Pod logs:"
          kubectl logs "$latest_failed_pod" -n cf-gitea --tail=50
        fi
        
        log_info "All failed pods:"
        kubectl get pods -n cf-gitea -l job-name=gitea-init-job --field-selector=status.phase=Failed --no-headers
        
        exit 1
      fi
      
      # Brief sleep before checking again
      sleep 5
      elapsed=$((elapsed + 5))
      
      # Progress logging every 30 seconds
      if [ $((elapsed % 30)) -eq 0 ]; then
        log_info "Still waiting for Gitea init job... (${elapsed}s elapsed)"
      fi
    done
    
    # kubectl wait completed, check the result
    if wait $wait_pid; then
      log_info "Gitea init job completed successfully"
    else
      # Job failed or timed out
      local job_failed=$(kubectl get job gitea-init-job -n cf-gitea -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
      if [ "$job_failed" -gt 0 ]; then
        log_info "ERROR: Gitea init job failed after all retries"
        
        # Show failure details
        log_info "Job conditions:"
        kubectl describe job gitea-init-job -n cf-gitea | grep -A 10 "Conditions:"
        
        log_info "Pod logs:"
        kubectl logs job/gitea-init-job -n cf-gitea --tail=30
      else
        log_info "ERROR: Gitea init job timed out"
        
        # Show current status
        log_info "Current job status:"
        kubectl describe job gitea-init-job -n cf-gitea
        
        log_info "Pod logs:"
        kubectl logs job/gitea-init-job -n cf-gitea --tail=50
      fi
      
      exit 1
    fi
  fi
  
  # Cleanup temp directory
  rm -rf "${TEMP_DIR}"
}

# Render specific cluster-forge child apps (for --apps filtering)
render_cluster_forge_child_apps() {
  
  # Create a temporary values file with only the requested apps enabled
  local temp_values="/tmp/filtered_values.yaml"
  cat > "$temp_values" << EOF
global:
  domain: ${DOMAIN}
enabledApps: []
apps: {}
EOF
  
  # Copy specific app configurations from the main values
  local IFS=','
  for app in $APPS; do
    # Skip disabled apps
    if is_disabled_app "$app"; then
      log_info "  Skipping disabled app: $app"
      continue
    fi
    # Add to enabledApps list
    yq eval ".enabledApps += [\"$app\"]" -i "$temp_values"
    
    # Copy app configuration if it exists in values.yaml
    if yq eval ".apps | has(\"$app\")" "${SOURCE_ROOT}/root/${VALUES_FILE}" 2>/dev/null | grep -q "true"; then
      yq eval ".apps[\"$app\"] = load(\"${SOURCE_ROOT}/root/${VALUES_FILE}\").apps[\"$app\"]" -i "$temp_values"
    fi
    
    # Merge size-specific configuration if it exists
    if [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
      if yq eval ".apps | has(\"$app\")" "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" 2>/dev/null | grep -q "true"; then
        yq eval ".apps[\"$app\"] = (.apps[\"$app\"] // {}) * load(\"${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}\").apps[\"$app\"]" -i "$temp_values"
      fi
    fi
  done
  
  # Render only the cluster-apps template with filtered values
  helm template cluster-forge "${SOURCE_ROOT}/root" \
      --show-only templates/cluster-apps.yaml \
      --values "$temp_values" \
      --set clusterForge.targetRevision="${TARGET_REVISION}" \
      --set externalValues.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git" \
      --set clusterForge.repoUrl="http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git" \
      --namespace argocd \
      --kube-version "${KUBE_VERSION}" | apply_or_template -f -
  
  # Clean up
  rm -f "$temp_values"
}

apply_cluster_forge_parent_app() {
  # Create cluster-forge parent app only (not all apps)
  log_info "=== Creating ClusterForge Parent App ==="
  log_info "Target revision: $TARGET_REVISION"
  

  
  helm template cluster-forge "${SOURCE_ROOT}/root" \
      --show-only templates/cluster-forge.yaml \
      --values "${SOURCE_ROOT}/root/${VALUES_FILE}" \
      --values "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" \
      --set global.clusterSize="${SIZE_VALUES_FILE}" \
      --set global.domain="${DOMAIN}" \
      --set clusterForge.targetRevision="${TARGET_REVISION}" \
      --namespace argocd \
      --kube-version "${KUBE_VERSION}" | apply_or_template -f -
}

# Check if requested apps are cluster-forge child apps
is_cluster_forge_child_app() {
  local app="$1"
  # Check if the app is defined in the values.yaml apps section
  local app_config=$(yq eval ".apps[\"$app\"]" "${SOURCE_ROOT}/root/${VALUES_FILE}" 2>/dev/null)
  [ "$app_config" != "null" ] && return 0
  return 1
}

main() {
  parse_args "$@"
  # Use silent dependency check when using --apps or template mode for cleaner output
  if [ -z "$APPS" ] && [ "$TEMPLATE_ONLY" = false ]; then
    if [ "$SKIP_DEPENDENCY_CHECK" = false ]; then
      check_dependencies
    fi
    validate_args
    print_summary
  else
    # For --apps mode or template mode, check deps silently and skip verbose output
    if [ "$SKIP_DEPENDENCY_CHECK" = false ]; then
      check_dependencies true
    fi
    validate_args
  fi
  
  # If --aiwb-only, prepend the standard aiwb-only disabled patterns to DISABLED_APPS
  if [ "$AIWB_ONLY" = true ]; then
    local aiwb_disabled="airm,airm-infra-cnpg,airm-infra-external-secrets,airm-infra-rabbitmq,kaiwo*,rabbitmq"
    if [ -n "$DISABLED_APPS" ]; then
      DISABLED_APPS="${aiwb_disabled},${DISABLED_APPS}"
    else
      DISABLED_APPS="${aiwb_disabled}"
    fi
    log_info "NOTE: --aiwb-only active; disabled apps set to: $DISABLED_APPS"
  fi

  # Remove disabled apps from --apps list (disabled takes priority)
  if [ -n "$APPS" ] && [ -n "$DISABLED_APPS" ]; then
    local filtered_apps=""
    local IFS=','
    for app in $APPS; do
      if is_disabled_app "$app"; then
        log_info "NOTE: '$app' is in both --apps and --disabled-apps; skipping it"
      else
        filtered_apps="${filtered_apps:+$filtered_apps,}$app"
      fi
    done
    APPS="$filtered_apps"
  fi

  # If specific apps are requested, check if they're cluster-forge child apps
  if [ -n "$APPS" ]; then
    local has_bootstrap_apps=false
    local has_child_apps=false
    local child_apps=""
    
    IFS=',' read -ra APP_ARRAY <<< "$APPS"
    for app in "${APP_ARRAY[@]}"; do
      case "$app" in
        namespaces|argocd|openbao|gitea|cluster-forge)
          has_bootstrap_apps=true
          ;;
        *)
          if is_cluster_forge_child_app "$app"; then
            has_child_apps=true
            if [ -z "$child_apps" ]; then
              child_apps="$app"
            else
              child_apps="$child_apps,$app"
            fi
          else
            echo "WARNING: Unknown app '$app'. Available bootstrap apps: namespaces, argocd, openbao, gitea, cluster-forge"
            echo "Or specify any cluster-forge child app from values.yaml"
          fi
          ;;
      esac
    done
    
    # Handle bootstrap apps
    if [ "$has_bootstrap_apps" = true ]; then
      should_run namespaces      && create_namespaces
      should_run argocd          && bootstrap_argocd
      should_run openbao         && bootstrap_openbao
      should_run gitea           && bootstrap_gitea
      should_run cluster-forge   && apply_cluster_forge_parent_app
    fi
    
    # Handle cluster-forge child apps
    if [ "$has_child_apps" = true ]; then
      # Temporarily set APPS to only child apps for the render function
      local original_apps="$APPS"
      APPS="$child_apps"
      render_cluster_forge_child_apps
      APPS="$original_apps"
    fi
  else
    # Default behavior - run all bootstrap components
    log_info "🚀 Running full bootstrap sequence..."
    log_info "📋 Bootstrap order: namespaces → argocd → openbao → gitea → cluster-forge"
    
    if should_run namespaces; then
      log_info "📦 Step 1/5: Creating namespaces"
      create_namespaces
    else
      log_info "⏭️  Step 1/5: Skipping namespaces"
    fi
    
    if should_run argocd; then
      log_info "📦 Step 2/5: Bootstrapping ArgoCD"
      bootstrap_argocd
    else
      log_info "⏭️  Step 2/5: Skipping ArgoCD"
    fi
    
    if should_run openbao; then
      log_info "📦 Step 3/5: Bootstrapping OpenBao"
      bootstrap_openbao
    else
      log_info "⏭️  Step 3/5: Skipping OpenBao"
    fi
    
    if should_run gitea; then
      log_info "📦 Step 4/5: Bootstrapping Gitea"
      bootstrap_gitea
    else
      log_info "⏭️  Step 4/5: Skipping Gitea"
    fi
    
    if should_run cluster-forge; then
      log_info "📦 Step 5/5: Creating ClusterForge parent app"
      apply_cluster_forge_parent_app
    else
      log_info "⏭️  Step 5/5: Skipping ClusterForge"
    fi
    
    log_info "✅ Bootstrap sequence completed"
  fi
}

main "$@"