#!/bin/bash

set -euo pipefail

# Function to display help
show_help() {
    cat << 'EOF'
Cluster-Forge Bootstrap Script

USAGE:
    bootstrap.sh [DOMAIN] [VALUES_FILE]
    bootstrap.sh [VALUES_FILE]
    bootstrap.sh [-h|--help]

DESCRIPTION:
    Bootstraps a Cluster-Forge deployment by setting up ArgoCD, OpenBao, 
    Gitea, and deploying the main Cluster-Forge application.
    
    Both domain and cluster size can be auto-detected from the bloom-config 
    configmap in the default namespace, or provided as arguments.

ARGUMENTS:
    DOMAIN          Cluster domain (e.g., my-cluster.example.com)
                    If omitted, reads from bloom-config configmap (data.domain key)
                    
    VALUES_FILE     Helm values file to use (values.yaml, values_m.yaml, values_l.yaml)
                    If omitted, cluster size is auto-detected from bloom-config configmap 
                    (data.CLUSTER_SIZE key) and mapped to appropriate values file

OPTIONS:
    -h, --help      Show this help message and exit

CLUSTER SIZES:
    small           Single-node deployment (values.yaml)
                    - Target: Workstation/Gaming PC/Single Developer
                    - 1 node, 16-32 vCPU, 64-128 GB RAM, 1-2 GPUs
                    - Storage: 1-4 TB NVMe, direct storage class
                    
    medium          Team environment (values.yaml + values_m.yaml)  
                    - Target: Small team, shared environment (5-20 users)
                    - 1-3 nodes, 32-64 vCPU, 128-256 GB RAM, up to 8 GPUs
                    - Storage: 4-16 TB NVMe, multinode storage class
                    
    large           Production scale (values.yaml + values_l.yaml)
                    - Target: Production deployment (10s-100s users)
                    - 6+ nodes, 32-96 vCPU workers, 256-1024 GB RAM, 8+ GPUs
                    - Storage: 10-100+ TB NVMe, default + mlstorage classes

EXAMPLES:
    # Auto-detect both domain and cluster size from bloom-config configmap
    bootstrap.sh
    
    # Use provided domain, auto-detect cluster size
    bootstrap.sh my-cluster.example.com
    
    # Auto-detect domain, force medium cluster size
    bootstrap.sh values_m.yaml
    
    # Use provided domain, force large cluster size  
    bootstrap.sh my-cluster.example.com values_l.yaml

BLOOM CONFIGMAP:
    The script can read configuration from a bloom-config configmap:
    
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: bloom-config
      namespace: default
    data:
      domain: "your-cluster.example.com"      # Required if no domain argument
      CLUSTER_SIZE: "medium"                  # Optional: small, medium, large

PREREQUISITES:
    - kubectl configured and connected to target cluster
    - helm CLI available
    - yq CLI available for YAML processing
    - openssl available for password generation

EXIT CODES:
    0    Success
    1    Missing required arguments or configuration
    2    Validation failure (missing files, charts, etc.)

For more information, see scripts/bootstrap.md
EOF
}

# Check for help flag
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

# Parse arguments intelligently 
parse_arguments() {
    local arg1="${1:-}"
    local arg2="${2:-}"
    
    # Detect if arg1 is a domain or values file
    local domain=""
    local values_file=""
    
    # Check if arg1 looks like a values file
    if [[ "$arg1" =~ ^values.*\.yaml$ ]]; then
        # arg1 is a values file, no domain provided
        values_file="$arg1"
        values_file_arg_pos=1
    elif [ -n "$arg1" ] && [[ ! "$arg1" =~ ^values.*\.yaml$ ]]; then
        # arg1 looks like a domain
        domain="$arg1"
        values_file="$arg2"
        values_file_arg_pos=2
    else
        # No arguments provided or arg1 is empty
        values_file_arg_pos=1
    fi
    
    # If no domain was provided as argument, try bloom-config configmap
    if [ -z "$domain" ]; then
        if kubectl get configmap bloom-config -n default >/dev/null 2>&1; then
            domain=$(kubectl get configmap bloom-config -n default -o jsonpath='{.data.domain}' 2>/dev/null || echo "")
            
            if [ -n "$domain" ]; then
                echo "Detected domain from bloom-config configmap: $domain" >&2
            else
                echo "INFO: bloom-config configmap found but no domain key present" >&2
            fi
        else
            echo "INFO: bloom-config configmap not found in default namespace" >&2
        fi
    fi
    
    # Export results
    PARSED_DOMAIN="$domain"
    PARSED_VALUES_FILE="$values_file"
    VALUES_FILE_ARG_POS="$values_file_arg_pos"
}

# Parse command line arguments
parse_arguments "$@"
DOMAIN="$PARSED_DOMAIN"

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain is required but not provided" >&2
    echo "" >&2
    echo "Domain can be provided as an argument or via bloom-config configmap." >&2
    echo "Use 'bootstrap.sh --help' for detailed usage information." >&2
    echo "" >&2
    echo "Quick examples:" >&2
    echo "  bootstrap.sh                              # Auto-detect from bloom-config configmap" >&2  
    echo "  bootstrap.sh my-cluster.example.com       # Explicit domain" >&2
    echo "  bootstrap.sh values_m.yaml                # Auto-detect domain, force medium" >&2
    exit 1
fi

KUBE_VERSION=1.33

# Setup logging
LOG_FILE="/tmp/cluster-forge-bootstrap-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1 4>&2  # Save original stdout/stderr
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Pretty output functions
print_header() {
    local message="$1"
    echo ""
    echo "🚀 $message" | tee -a "$LOG_FILE" >&3
}

print_step() {
    local step="$1"
    local message="$2"
    echo "[$step/4] 🔧 $message" | tee -a "$LOG_FILE" >&3
}

print_substep() {
    local message="$1"
    echo "  ⚙️  $message" | tee -a "$LOG_FILE" >&3
}

print_success() {
    local message="$1"
    echo "  ✅ $message" | tee -a "$LOG_FILE" >&3
}

print_info() {
    local message="$1"
    echo "  ℹ️  $message" | tee -a "$LOG_FILE" >&3
}

print_warning() {
    local message="$1"
    echo "  ⚠️  $message" | tee -a "$LOG_FILE" >&3
}

print_final() {
    local message="$1"
    echo ""
    echo "🎉 $message" | tee -a "$LOG_FILE" >&3
}

# Spinner for long operations
spinner() {
    local pid=$1
    local message="$2"
    local delay=0.1
    local spinstr='|/-\'
    
    echo -n "  ⏳ $message " >&3
    
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b" >&3
    done
    
    wait $pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "   ✅\n" >&3
    else
        printf "   ❌\n" >&3
        return $exit_code
    fi
}

# Function to run commands with pretty output
run_with_spinner() {
    local message="$1"
    shift
    
    # Run command in background and capture its PID
    "$@" &
    local pid=$!
    
    # Show spinner while command runs
    spinner $pid "$message"
    return $?
}

# Determine project root directory - work from any execution location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find project root by looking for characteristic files (Chart.yaml in root/, sources/ dir)
find_project_root() {
    local current_dir="$1"
    
    while [ "$current_dir" != "/" ]; do
        if [ -f "$current_dir/root/Chart.yaml" ] && [ -d "$current_dir/sources" ]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done
    
    # Fallback: assume script is in scripts/ subdirectory  
    if [ -f "${SCRIPT_DIR}/../root/Chart.yaml" ] && [ -d "${SCRIPT_DIR}/../sources" ]; then
        echo "$(cd "${SCRIPT_DIR}/.." && pwd)"
        return 0
    fi
    
    echo "ERROR: Could not find project root. Ensure script is in cluster-forge project." >&2
    exit 1
}

PROJECT_ROOT="$(find_project_root "$SCRIPT_DIR")"
ROOT_DIR="$PROJECT_ROOT/root"
SOURCES_DIR="$PROJECT_ROOT/sources"

# Detect cluster size and build values file arguments
detect_cluster_config() {
    local provided_values_file="$PARSED_VALUES_FILE"
    
    # If a values file was explicitly provided, determine what it is
    if [ -n "$provided_values_file" ]; then
        case "$provided_values_file" in
            "values.yaml")
                echo "small values.yaml"
                ;;
            "values_m.yaml")
                echo "medium values.yaml values_m.yaml"
                ;;
            "values_l.yaml") 
                echo "large values.yaml values_l.yaml"
                ;;
            *)
                echo "WARNING: Unknown values file '$provided_values_file', treating as custom single file" >&2
                echo "custom $provided_values_file"
                ;;
        esac
        return 0
    fi
    
    # Try to detect cluster size from bloom-config configmap
    local cluster_size=""
    if kubectl get configmap bloom-config -n default >/dev/null 2>&1; then
        cluster_size=$(kubectl get configmap bloom-config -n default -o jsonpath='{.data.CLUSTER_SIZE}' 2>/dev/null || echo "")
        
        if [ -n "$cluster_size" ]; then
            echo "Detected cluster size from bloom-config configmap: $cluster_size" >&2
            
            case "$cluster_size" in
                "small"|"")
                    echo "small values.yaml"
                    ;;
                "medium")
                    echo "medium values.yaml values_m.yaml"
                    ;;
                "large")
                    echo "large values.yaml values_l.yaml"
                    ;;
                *)
                    echo "WARNING: Unknown cluster size '$cluster_size' in bloom-config configmap, defaulting to small" >&2
                    echo "small values.yaml"
                    ;;
            esac
            return 0
        fi
    else
        echo "INFO: bloom-config configmap not found, defaulting to small cluster" >&2
    fi
    
    # Default to small
    echo "small values.yaml"
}

# Parse cluster configuration (using already parsed values file)
CLUSTER_CONFIG="$(detect_cluster_config)"
CLUSTER_SIZE="$(echo "$CLUSTER_CONFIG" | cut -d' ' -f1)"
VALUES_FILES="$(echo "$CLUSTER_CONFIG" | cut -d' ' -f2-)"

# Build helm values arguments
build_values_args() {
    local values_args=""
    for values_file in $VALUES_FILES; do
        if [ -f "$ROOT_DIR/$values_file" ]; then
            values_args="$values_args --values $ROOT_DIR/$values_file"
        else
            echo "ERROR: Values file not found: $ROOT_DIR/$values_file" >&2
            exit 1
        fi
    done
    echo "$values_args"
}

VALUES_ARGS="$(build_values_args)"

# Validate required directories exist
if [ ! -d "$ROOT_DIR" ]; then
    echo "ERROR: Root directory not found at $ROOT_DIR" >&2
    exit 1
fi

if [ ! -d "$SOURCES_DIR" ]; then
    echo "ERROR: Sources directory not found at $SOURCES_DIR" >&2
    exit 1
fi

# Validate all values files exist
for values_file in $VALUES_FILES; do
    if [ ! -f "$ROOT_DIR/$values_file" ]; then
        echo "ERROR: Values file not found at $ROOT_DIR/$values_file" >&2
        echo "Available values files:" >&2
        ls -1 "$ROOT_DIR"/values*.yaml 2>/dev/null || echo "  No values files found" >&2
        exit 1
    fi
done

echo "✓ Project root: $PROJECT_ROOT"
if [ -n "$PARSED_VALUES_FILE" ]; then
    echo "✓ Domain: $DOMAIN (auto-detected from bloom configmap)"
    echo "✓ Values files: $VALUES_FILES (provided as argument)"
elif [ "${1:-}" = "$DOMAIN" ]; then
    echo "✓ Domain: $DOMAIN (provided as argument)"
    echo "✓ Values files: $VALUES_FILES (auto-detected from bloom configmap)"
else
    echo "✓ Domain: $DOMAIN (auto-detected from bloom configmap)"
    echo "✓ Values files: $VALUES_FILES (auto-detected from bloom configmap)"
fi

# Display cluster size information
case "$CLUSTER_SIZE" in
    "small")
        echo "✓ Cluster size: SMALL (single-node, workstation deployment)"
        ;;
    "medium")
        echo "✓ Cluster size: MEDIUM (team environment, 1-3 nodes)"
        echo "  Using base configuration + medium overrides"
        ;;
    "large")
        echo "✓ Cluster size: LARGE (production scale, 6+ nodes)"
        echo "  Using base configuration + large overrides"
        ;;
    "custom")
        echo "✓ Cluster size: CUSTOM (user-provided configuration)"
        ;;
esac

bootstrapArgocd() {
  print_step "1" "Bootstrapping ArgoCD GitOps Controller"
  
  print_substep "Creating argocd namespace"
  kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  # Verify ArgoCD chart directory exists
  local argocd_chart="$SOURCES_DIR/argocd/8.3.5"
  if [ ! -d "$argocd_chart" ]; then
    echo "ERROR: ArgoCD chart not found at $argocd_chart" >&2
    exit 1
  fi

  print_substep "Preparing ArgoCD configuration"
  # Create temporary merged values file for ArgoCD  
  local merged_config="/tmp/bootstrap-argocd-$$.yaml"
  
  # Start with empty config and merge each values file's ArgoCD config
  echo "apps:" > "$merged_config"
  echo "  argocd:" >> "$merged_config" 
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.argocd.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.argocd.valuesObject *= select(fileIndex == 1).apps.argocd.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp" 2>>"$LOG_FILE"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done

  print_substep "Deploying ArgoCD components"
  helm template --release-name argocd  \
    "$argocd_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace argocd \
    --set global.domain="https://argocd.${DOMAIN}" \
    --values <(yq '.apps.argocd.valuesObject' "$merged_config") \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1
  
  rm -f "$merged_config"
  
  # Wait for components with pretty spinner
  run_with_spinner "Waiting for ArgoCD controller" kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
  run_with_spinner "Waiting for ArgoCD applicationset" kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout=300s  
  run_with_spinner "Waiting for ArgoCD redis" kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
  run_with_spinner "Waiting for ArgoCD repo server" kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
  
  print_success "ArgoCD bootstrap complete"
}

bootstrapOpenbao() {
  print_step "2" "Bootstrapping OpenBao Secret Management"
  
  print_substep "Creating cf-openbao namespace"
  kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  # Verify OpenBao chart directory exists
  local openbao_chart="$SOURCES_DIR/openbao/0.18.2"
  if [ ! -d "$openbao_chart" ]; then
    echo "ERROR: OpenBao chart not found at $openbao_chart" >&2
    exit 1
  fi

  print_substep "Preparing OpenBao configuration"
  # Create temporary merged values file for OpenBao
  local merged_config="/tmp/bootstrap-openbao-$$.yaml"
  
  echo "apps:" > "$merged_config"
  echo "  openbao:" >> "$merged_config"
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.openbao.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.openbao.valuesObject *= select(fileIndex == 1).apps.openbao.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp" 2>>"$LOG_FILE"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done

  print_substep "Deploying OpenBao components"
  helm template --release-name openbao \
    "$openbao_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace cf-openbao \
    --values <(yq '.apps.openbao.valuesObject' "$merged_config") \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1
  
  rm -f "$merged_config"

  run_with_spinner "Waiting for OpenBao pod startup" kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

  # Verify init job template exists
  local init_job_template="$SCRIPT_DIR/init-openbao-job"
  if [ ! -d "$init_job_template" ]; then
    echo "ERROR: OpenBao init job template not found at $init_job_template" >&2
    exit 1
  fi

  print_substep "Running OpenBao initialization"
  helm template --release-name openbao-init \
    "$init_job_template" \
    --kube-version="${KUBE_VERSION}" \
    --set domain="${DOMAIN}" \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1

  run_with_spinner "Waiting for OpenBao initialization" kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
  print_success "OpenBao bootstrap complete"
}

bootstrapGitea() {
  print_step "3" "Bootstrapping Gitea Git Repository Server"
  
  print_substep "Creating cf-gitea namespace"
  kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  print_substep "Creating cluster-forge configuration"
  # Create initial-cf-values configmap with merged configuration
  local merged_values="/tmp/bootstrap-cf-values-$$.yaml"
  
  # Merge all values files
  cp "$ROOT_DIR/$(echo $VALUES_FILES | cut -d' ' -f1)" "$merged_values"
  for values_file in $(echo $VALUES_FILES | cut -d' ' -f2-); do
    if [ -f "$ROOT_DIR/$values_file" ]; then
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
        "$merged_values" "$ROOT_DIR/$values_file" > "${merged_values}.tmp" 2>>"$LOG_FILE"
      mv "${merged_values}.tmp" "$merged_values"
    fi
  done
  
  VALUES=$(cat "$merged_values" | yq ".global.domain = \"${DOMAIN}\"" 2>>"$LOG_FILE")
  kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f - >/dev/null 2>&1
  
  rm -f "$merged_values"
  
  # Generate admin password  
  print_substep "Generating Gitea admin credentials"
  GITEA_INITIAL_ADMIN_PASSWORD=$(openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32)
  echo "    🔑 Admin password: $GITEA_INITIAL_ADMIN_PASSWORD" | tee -a "$LOG_FILE" >&3
  kubectl create secret generic gitea-admin-credentials \
    --namespace=cf-gitea \
    --from-literal=username=silogen-admin \
    --from-literal=password="$GITEA_INITIAL_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

  # Verify Gitea chart directory exists
  local gitea_chart="$SOURCES_DIR/gitea/12.3.0"
  if [ ! -d "$gitea_chart" ]; then
    echo "ERROR: Gitea chart not found at $gitea_chart" >&2
    exit 1
  fi

  print_substep "Preparing Gitea configuration"
  # Create temporary merged values file for Gitea
  local merged_config="/tmp/bootstrap-gitea-$$.yaml"
  
  echo "apps:" > "$merged_config"
  echo "  gitea:" >> "$merged_config"
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.gitea.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.gitea.valuesObject *= select(fileIndex == 1).apps.gitea.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp" 2>>"$LOG_FILE"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done
  
  print_substep "Deploying Gitea components"
  helm template --release-name gitea \
    "$gitea_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace cf-gitea \
    --set clusterDomain="${DOMAIN}" \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" \
    --values <(yq '.apps.gitea.valuesObject' "$merged_config") \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1
  
  rm -f "$merged_config"
  
  run_with_spinner "Waiting for Gitea deployment" kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s
  
  # Verify init job template exists
  local gitea_init_template="$SCRIPT_DIR/init-gitea-job"
  if [ ! -d "$gitea_init_template" ]; then
    echo "ERROR: Gitea init job template not found at $gitea_init_template" >&2
    exit 1
  fi

  print_substep "Running Gitea initialization"
  helm template --release-name gitea-init \
    "$gitea_init_template" \
    --kube-version="${KUBE_VERSION}" \
    --set domain="${DOMAIN}" \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1
  
  run_with_spinner "Waiting for Gitea initialization" kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea
  print_success "Gitea bootstrap complete"
}

deployClusterForge() {
  print_step "4" "Deploying Cluster-Forge Applications"
  
  # Verify root chart exists
  if [ ! -f "$ROOT_DIR/Chart.yaml" ]; then
    echo "ERROR: Cluster-Forge chart not found at $ROOT_DIR/Chart.yaml" >&2
    exit 1
  fi

  print_substep "Deploying ArgoCD applications"
  helm template "$ROOT_DIR" \
    --kube-version="${KUBE_VERSION}" \
    --set global.domain="${DOMAIN}" \
    $VALUES_ARGS \
    2>>"$LOG_FILE" | kubectl apply -f - >/dev/null 2>&1
  
  print_success "Cluster-Forge applications deployed"
  print_info "ArgoCD will now sync all enabled applications"
}

#### MAIN ####
print_header "Starting Cluster-Forge Bootstrap"
echo "  🌐 Domain: $DOMAIN" | tee -a "$LOG_FILE" >&3
echo "  🏷️  Size: $(echo "$CLUSTER_SIZE" | tr '[:lower:]' '[:upper:]')" | tee -a "$LOG_FILE" >&3  
echo "  📄 Config: $VALUES_FILES" | tee -a "$LOG_FILE" >&3
echo "  📋 Log: $LOG_FILE" | tee -a "$LOG_FILE" >&3

bootstrapArgocd
bootstrapOpenbao  
bootstrapGitea
deployClusterForge

print_final "Cluster-Forge Bootstrap Complete!"
echo ""
echo "🎯 Access Your Cluster:" | tee -a "$LOG_FILE" >&3
echo "  🌐 ArgoCD:  https://argocd.$DOMAIN" | tee -a "$LOG_FILE" >&3
echo "  📚 Gitea:   https://gitea.$DOMAIN" | tee -a "$LOG_FILE" >&3
echo "  🔐 OpenBao: https://openbao.$DOMAIN" | tee -a "$LOG_FILE" >&3
echo ""
echo "📋 Detailed logs available at: $LOG_FILE" | tee -a "$LOG_FILE" >&3
echo ""
echo "🚀 Next Steps:" | tee -a "$LOG_FILE" >&3
echo "  1. Check ArgoCD for application sync status" | tee -a "$LOG_FILE" >&3
echo "  2. Retrieve credentials using 'kubectl get secrets'" | tee -a "$LOG_FILE" >&3  
echo "  3. Monitor deployment progress in ArgoCD UI" | tee -a "$LOG_FILE" >&3
echo ""
echo "✨ Happy GitOps! The fire of the forge eliminates impurities! 🔥" | tee -a "$LOG_FILE" >&3