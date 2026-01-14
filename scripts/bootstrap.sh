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
  echo "=== Bootstrapping ArgoCD ==="
  
  kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -

  # Verify ArgoCD chart directory exists
  local argocd_chart="$SOURCES_DIR/argocd/8.3.5"
  if [ ! -d "$argocd_chart" ]; then
    echo "ERROR: ArgoCD chart not found at $argocd_chart" >&2
    exit 1
  fi

  # Create temporary merged values file for ArgoCD  
  local merged_config="/tmp/bootstrap-argocd-$$.yaml"
  
  # Start with empty config and merge each values file's ArgoCD config
  echo "apps:" > "$merged_config"
  echo "  argocd:" >> "$merged_config" 
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.argocd.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.argocd.valuesObject *= select(fileIndex == 1).apps.argocd.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done

  helm template --release-name argocd  \
    "$argocd_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace argocd \
    --set global.domain="https://argocd.${DOMAIN}" \
    --values <(yq '.apps.argocd.valuesObject' "$merged_config") \
    | kubectl apply -f -
  
  rm -f "$merged_config"
  
  echo "Waiting for ArgoCD components to be ready..."
  kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
  kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout=300s
  kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
  kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
  echo "ArgoCD bootstrap complete"
}

bootstrapOpenbao() {
  echo "=== Bootstrapping OpenBao ==="
  
  kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

  # Verify OpenBao chart directory exists
  local openbao_chart="$SOURCES_DIR/openbao/0.18.2"
  if [ ! -d "$openbao_chart" ]; then
    echo "ERROR: OpenBao chart not found at $openbao_chart" >&2
    exit 1
  fi

  # Create temporary merged values file for OpenBao
  local merged_config="/tmp/bootstrap-openbao-$$.yaml"
  
  echo "apps:" > "$merged_config"
  echo "  openbao:" >> "$merged_config"
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.openbao.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.openbao.valuesObject *= select(fileIndex == 1).apps.openbao.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done

  helm template --release-name openbao \
    "$openbao_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace cf-openbao \
    --values <(yq '.apps.openbao.valuesObject' "$merged_config") \
    | kubectl apply -f -
  
  rm -f "$merged_config"

  echo "Waiting for OpenBao pod to be ready..."
  kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

  # Verify init job template exists
  local init_job_template="$SCRIPT_DIR/init-openbao-job"
  if [ ! -d "$init_job_template" ]; then
    echo "ERROR: OpenBao init job template not found at $init_job_template" >&2
    exit 1
  fi

  helm template --release-name openbao-init \
    "$init_job_template" \
    --kube-version="${KUBE_VERSION}" \
    --set domain="${DOMAIN}" \
    | kubectl apply -f -

  echo "Waiting for OpenBao initialization to complete..."
  kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
  echo "OpenBao bootstrap complete"
}

bootstrapGitea() {
  echo "=== Bootstrapping Gitea ==="
  
  kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -

  # Create initial-cf-values configmap with merged configuration
  echo "Creating cluster-forge values configmap..."
  local merged_values="/tmp/bootstrap-cf-values-$$.yaml"
  
  # Merge all values files
  cp "$ROOT_DIR/$(echo $VALUES_FILES | cut -d' ' -f1)" "$merged_values"
  for values_file in $(echo $VALUES_FILES | cut -d' ' -f2-); do
    if [ -f "$ROOT_DIR/$values_file" ]; then
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
        "$merged_values" "$ROOT_DIR/$values_file" > "${merged_values}.tmp"
      mv "${merged_values}.tmp" "$merged_values"
    fi
  done
  
  VALUES=$(cat "$merged_values" | yq ".global.domain = \"${DOMAIN}\"")
  kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -
  
  rm -f "$merged_values"
  
  # Generate admin password  
  GITEA_INITIAL_ADMIN_PASSWORD=$(openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32)
  echo "Creating Gitea admin credentials (password: $GITEA_INITIAL_ADMIN_PASSWORD)"
  kubectl create secret generic gitea-admin-credentials \
    --namespace=cf-gitea \
    --from-literal=username=silogen-admin \
    --from-literal=password="$GITEA_INITIAL_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Verify Gitea chart directory exists
  local gitea_chart="$SOURCES_DIR/gitea/12.3.0"
  if [ ! -d "$gitea_chart" ]; then
    echo "ERROR: Gitea chart not found at $gitea_chart" >&2
    exit 1
  fi
  
  # Create temporary merged values file for Gitea
  local merged_config="/tmp/bootstrap-gitea-$$.yaml"
  
  echo "apps:" > "$merged_config"
  echo "  gitea:" >> "$merged_config"
  echo "    valuesObject: {}" >> "$merged_config"
  
  for values_file in $VALUES_FILES; do
    if yq -e '.apps.gitea.valuesObject' "$ROOT_DIR/$values_file" >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0).apps.gitea.valuesObject *= select(fileIndex == 1).apps.gitea.valuesObject' \
        "$merged_config" "$ROOT_DIR/$values_file" > "${merged_config}.tmp"
      mv "${merged_config}.tmp" "$merged_config"
    fi
  done
  
  helm template --release-name gitea \
    "$gitea_chart" \
    --kube-version="${KUBE_VERSION}" \
    --namespace cf-gitea \
    --set clusterDomain="${DOMAIN}" \
    --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" \
    --values <(yq '.apps.gitea.valuesObject' "$merged_config") \
    | kubectl apply -f -
  
  rm -f "$merged_config"
  
  echo "Waiting for Gitea deployment to be ready..."
  kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s
  
  # Verify init job template exists
  local gitea_init_template="$SCRIPT_DIR/init-gitea-job"
  if [ ! -d "$gitea_init_template" ]; then
    echo "ERROR: Gitea init job template not found at $gitea_init_template" >&2
    exit 1
  fi

  helm template --release-name gitea-init \
    "$gitea_init_template" \
    --kube-version="${KUBE_VERSION}" \
    --set domain="${DOMAIN}" \
    | kubectl apply -f -
  
  echo "Waiting for Gitea initialization to complete..."
  kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea
  echo "Gitea bootstrap complete"
}

deployClusterForge() {
  echo "=== Deploying Cluster-Forge ==="
  
  # Verify root chart exists
  if [ ! -f "$ROOT_DIR/Chart.yaml" ]; then
    echo "ERROR: Cluster-Forge chart not found at $ROOT_DIR/Chart.yaml" >&2
    exit 1
  fi

  helm template "$ROOT_DIR" \
    --kube-version="${KUBE_VERSION}" \
    --set global.domain="${DOMAIN}" \
    $VALUES_ARGS \
    | kubectl apply -f -
  
  echo "Cluster-Forge deployment complete"
}

#### MAIN ####
echo "🚀 Starting Cluster-Forge bootstrap for domain: $DOMAIN"

bootstrapArgocd
echo ""
bootstrapOpenbao  
echo ""
bootstrapGitea
echo ""
deployClusterForge
echo ""
echo "✅ Cluster-Forge bootstrap complete! 🎉"
echo "🏷️  Cluster size: $(echo "$CLUSTER_SIZE" | tr '[:lower:]' '[:upper:]')"
echo "📄 Values files used: $VALUES_FILES"
echo "🌐 ArgoCD will be available at: https://argocd.$DOMAIN"
echo "📚 Gitea will be available at: https://gitea.$DOMAIN"