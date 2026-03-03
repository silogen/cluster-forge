#!/bin/bash

set -euo pipefail

LATEST_RELEASE="v1.8.0"

# Initialize variables
APPS=""
CLUSTER_SIZE="medium"  # Default to medium
DEFAULT_TIMEOUT="5m"
DOMAIN=""
KUBE_VERSION=1.33
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_DEPENDENCY_CHECK=false
TARGET_REVISION="$LATEST_RELEASE"
TEMPLATE_ONLY=false
VALUES_FILE="values.yaml"

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
          --airm-image-repository=url        Custom AIRM image repository for gitea-init job (e.g., ghcr.io/silogen, requires regcreds)
          --apps=app1[,app2,...]             Deploy (kubectl apply) specified components onlye
                                             options: namespaces, argocd, openbao, gitea, cluster-forge, or any cluster-forge child app (see values.yaml for app names)
                                             
          --cluster-size=[size],      -s     [size] can be one of small|medium|large, default: medium
          --help,                     -h     Show this help message and exit
          --skip-deps                        Skip dependency checking (not recommended)
          --target-revision,          -r     Git revision for ArgoCD to sync from, [tag|commit_hash|branch_name], default: $LATEST_RELEASE
          --template-only,            -t     Output YAML manifests to stdout instead of applying to cluster
        
        
        Examples:
          $0 compute.amd.com values_custom.yaml --cluster-size=large
          $0 112.100.97.17.nip.io
          $0 dev.example.com --cluster-size=small --target-revision=v1.8.0
          $0 dev.example.com -s=small -r=feature-branch
          $0 example.com --apps=openbao
          $0 example.com --apps=keycloak -t
          
        Bootstrap Behavior:
          • deploys ArgoCD + OpenBao + Gitea directly (essential infrastructure)
          • apply the cluster-forge application manifest (parent app only)
          • ArgoCD syncs remaining apps from specified target revision, respecting syncWaves and dependencies
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
      echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large]"
      echo "Use --help for more details"
      exit 1
  fi
  
  # Validate cluster size
  case "$CLUSTER_SIZE" in
    small|medium|large)
      ;;
    *)
      echo "ERROR: Invalid cluster size '$CLUSTER_SIZE'"
      echo "Valid sizes: small, medium, large"
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
        echo "WARNING: Size-specific values file not found: ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}"
        echo "Proceeding with base values file only: ${VALUES_FILE}"
        SIZE_VALUES_FILE=""
    else
        echo "Using size-specific values file: ${SIZE_VALUES_FILE}"
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
  # Create temporary values file for ArgoCD bootstrap
  cat > /tmp/argocd_bootstrap_values.yaml << EOF
global:
  domain: argocd.${DOMAIN}
EOF
  
  # Extract and merge ArgoCD values from the apps structure
  yq eval '.apps.argocd.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" >> /tmp/argocd_bootstrap_values.yaml
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    if yq eval '.apps.argocd.valuesObject // ""' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | grep -q .; then
      yq eval '.apps.argocd.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' /tmp/argocd_bootstrap_values.yaml - > /tmp/argocd_bootstrap_values_merged.yaml
      mv /tmp/argocd_bootstrap_values_merged.yaml /tmp/argocd_bootstrap_values.yaml
    fi
  fi
}

# ArgoCD bootstrap
bootstrap_argocd() {
  echo "=== ArgoCD Bootstrap ==="
  extract_argocd_values
  helm template --release-name argocd ${SOURCE_ROOT}/sources/argocd/8.3.5 --namespace argocd \
    --values /tmp/argocd_bootstrap_values.yaml \
    --kube-version=${KUBE_VERSION} | apply_or_template --server-side --field-manager=argocd-controller --force-conflicts -f -
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-redis -n argocd --timeout="${DEFAULT_TIMEOUT}"
    kubectl rollout status deploy/argocd-repo-server -n argocd --timeout="${DEFAULT_TIMEOUT}"
  fi
}



bootstrap_openbao() {
  echo "=== OpenBao Bootstrap ==="
  
  # Debug output for troubleshooting
  echo "Debug: SOURCE_ROOT='${SOURCE_ROOT}'"
  echo "Debug: VALUES_FILE='${VALUES_FILE}'"
  echo "Debug: SIZE_VALUES_FILE='${SIZE_VALUES_FILE}'"
  echo "Debug: CLUSTER_SIZE='${CLUSTER_SIZE}'"
  
  # Get OpenBao version from app path - using same method as main
  OPENBAO_VERSION=$(yq eval '.apps.openbao.path' "${SOURCE_ROOT}/root/${VALUES_FILE}" | cut -d'/' -f2)
  echo "OpenBao version: $OPENBAO_VERSION"
  
  # Extract OpenBao values from merged config - matching main approach
  echo "Extracting OpenBao values..."
  yq eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > /tmp/openbao_values.yaml || { echo "ERROR: Failed to extract OpenBao values from ${VALUES_FILE}"; exit 1; }
  
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    echo "Extracting OpenBao size-specific values from ${SIZE_VALUES_FILE}..."
    yq eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/openbao_size_values.yaml || { echo "ERROR: Failed to extract OpenBao size values from ${SIZE_VALUES_FILE}"; exit 1; }
  else
    echo "No size-specific values file, creating empty placeholder..."
    printf "# No size-specific values\n" > /tmp/openbao_size_values.yaml
  fi
  
  # Use server-side apply to match ArgoCD's field management strategy
  helm template --release-name openbao ${SOURCE_ROOT}/sources/openbao/${OPENBAO_VERSION} --namespace cf-openbao \
    -f /tmp/openbao_values.yaml \
    -f /tmp/openbao_size_values.yaml \
    --set ui.enabled=true \
    --kube-version=${KUBE_VERSION} | apply_or_template --server-side --field-manager=argocd-controller --force-conflicts -f -
    
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=100s
    
    # Create initial secrets config for init job (separate from ArgoCD-managed version)
    echo "Creating initial OpenBao secrets configuration..."
    cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-manager-cm.yaml | \
      sed "s|name: openbao-secret-manager-scripts|name: openbao-secret-manager-scripts-init|g" | kubectl apply -f -
    
    # Create initial secrets config for init job (separate from ArgoCD-managed version)  
    cat ${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml | \
      sed "s|{{ .Values.domain }}|${DOMAIN}|g" | \
      sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -
    
    # Pass OpenBao configuration to init script
    helm template --release-name openbao-init ${SOURCE_ROOT}/scripts/init-openbao-job \
      -f /tmp/openbao_values.yaml \
      --set domain="${DOMAIN}" \
      --kube-version=${KUBE_VERSION} | kubectl apply -f -
    kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
  fi
}



bootstrap_gitea() {
  echo "=== Gitea Bootstrap ==="
  generate_password() {
      openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
  }
  
  # Debug output for troubleshooting
  echo "Debug: SOURCE_ROOT='${SOURCE_ROOT}'"
  echo "Debug: VALUES_FILE='${VALUES_FILE}'"
  echo "Debug: SIZE_VALUES_FILE='${SIZE_VALUES_FILE}'"
  echo "Debug: CLUSTER_SIZE='${CLUSTER_SIZE}'"
  
  # Get Gitea version from app path - matching main approach
  GITEA_VERSION=$(yq eval '.apps.gitea.path' "${SOURCE_ROOT}/root/${VALUES_FILE}" | cut -d'/' -f2)
  echo "Gitea version: $GITEA_VERSION"
  
  # Create initial-cf-values configmap (complete values for gitea-init-job)
  # Use the complete root values.yaml with filled placeholders instead of simplified version
  cp "${SOURCE_ROOT}/root/${VALUES_FILE}" /tmp/complete_values.yaml
  
  # Fill in placeholder values using yq (these are used by gitea-init job)
  yq eval ".global.domain = \"${DOMAIN}\"" -i /tmp/complete_values.yaml
  if [ -n "${SIZE_VALUES_FILE}" ]; then
    yq eval ".global.clusterSize = \"${SIZE_VALUES_FILE}\"" -i /tmp/complete_values.yaml
  else
    yq eval ".global.clusterSize = \"values_${CLUSTER_SIZE}.yaml\"" -i /tmp/complete_values.yaml
  fi
  yq eval ".clusterForge.targetRevision = \"${TARGET_REVISION}\"" -i /tmp/complete_values.yaml
  
  # Merge with size-specific values if they exist
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' /tmp/complete_values.yaml "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/complete_values_merged.yaml
    mv /tmp/complete_values_merged.yaml /tmp/complete_values.yaml
  fi
  
  kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$(cat /tmp/complete_values.yaml)" --dry-run=client -o yaml | apply_or_template -n cf-gitea -f -
  
  kubectl create secret generic gitea-admin-credentials \
    --namespace=cf-gitea \
    --from-literal=username=silogen-admin \
    --from-literal=password=$(generate_password) \
    --dry-run=client -o yaml | apply_or_template -f -
  
  # Extract Gitea values like main does
  echo "Extracting Gitea values..."
  yq eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > /tmp/gitea_values.yaml || { echo "ERROR: Failed to extract Gitea values from ${VALUES_FILE}"; exit 1; }
  
  if [ -n "${SIZE_VALUES_FILE}" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
    echo "Extracting Gitea size-specific values from ${SIZE_VALUES_FILE}..."
    yq eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/gitea_size_values.yaml || { echo "ERROR: Failed to extract Gitea size values from ${SIZE_VALUES_FILE}"; exit 1; }
  else
    echo "No size-specific values file, creating empty placeholder..."
    printf "# No size-specific values\n" > /tmp/gitea_size_values.yaml
  fi
  
  # Bootstrap Gitea - matching main approach
  helm template --release-name gitea ${SOURCE_ROOT}/sources/gitea/${GITEA_VERSION} --namespace cf-gitea \
    -f /tmp/gitea_values.yaml \
    -f /tmp/gitea_size_values.yaml \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
    --kube-version=${KUBE_VERSION} | apply_or_template -f -
  
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl rollout status deploy/gitea -n cf-gitea --timeout="${DEFAULT_TIMEOUT}"
  fi
  
  # Gitea Init Job - preserve AIRM repository functionality
  HELM_ARGS="--release-name gitea-init ${SOURCE_ROOT}/scripts/init-gitea-job \
  --set clusterSize=${SIZE_VALUES_FILE:-values_${CLUSTER_SIZE}.yaml} \
  --set domain=${DOMAIN} \
  --set targetRevision=${TARGET_REVISION} \
  --kube-version=${KUBE_VERSION}"

  # Only add airmImageRepository if AIRM_IMAGE_REPOSITORY is set and non-empty
  if [ -n "${AIRM_IMAGE_REPOSITORY:-}" ]; then
    HELM_ARGS="${HELM_ARGS} --set airmImageRepository=${AIRM_IMAGE_REPOSITORY}"
  fi

  helm template ${HELM_ARGS} | apply_or_template -f -
  
  if [ "$TEMPLATE_ONLY" = false ]; then
    kubectl wait --for=condition=complete --timeout="${DEFAULT_TIMEOUT}" job/gitea-init-job -n cf-gitea
  fi
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
  echo "=== Creating ClusterForge Parent App ==="
  echo "Target revision: $TARGET_REVISION"
  

  
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
  # Use silent dependency check when using --apps for cleaner output
  if [ -z "$APPS" ]; then
    if [ "$SKIP_DEPENDENCY_CHECK" = false ]; then
      check_dependencies
    fi
    validate_args
    print_summary
  else
    # For --apps mode, check deps silently and skip verbose output
    if [ "$SKIP_DEPENDENCY_CHECK" = false ]; then
      check_dependencies true
    fi
    validate_args
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
    echo "🚀 Running full bootstrap sequence..."
    echo "📋 Bootstrap order: namespaces → argocd → openbao → gitea → cluster-forge"
    
    if should_run namespaces; then
      echo "📦 Step 1/5: Creating namespaces"
      create_namespaces
    else
      echo "⏭️  Step 1/5: Skipping namespaces"
    fi
    
    if should_run argocd; then
      echo "📦 Step 2/5: Bootstrapping ArgoCD"
      bootstrap_argocd
    else
      echo "⏭️  Step 2/5: Skipping ArgoCD"
    fi
    
    if should_run openbao; then
      echo "📦 Step 3/5: Bootstrapping OpenBao"
      bootstrap_openbao
    else
      echo "⏭️  Step 3/5: Skipping OpenBao"
    fi
    
    if should_run gitea; then
      echo "📦 Step 4/5: Bootstrapping Gitea"
      bootstrap_gitea
    else
      echo "⏭️  Step 4/5: Skipping Gitea"
    fi
    
    if should_run cluster-forge; then
      echo "📦 Step 5/5: Creating ClusterForge parent app"
      apply_cluster_forge_parent_app
    else
      echo "⏭️  Step 5/5: Skipping ClusterForge"
    fi
    
    echo "✅ Bootstrap sequence completed"
  fi
}

main "$@"