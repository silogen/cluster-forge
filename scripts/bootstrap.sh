#!/bin/bash

set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file]"
    echo ""
    echo "If values_file is not provided, cluster size will be auto-detected from:"
    echo "  - bloom configmap in default namespace (CLUSTER_SIZE key)"
    echo "  - Supported sizes: small (default), medium, large"
    echo ""
    echo "Examples:"
    echo "  $0 my-cluster.example.com              # Auto-detect size"
    echo "  $0 my-cluster.example.com values_m.yaml    # Force medium"
    echo "  $0 my-cluster.example.com values_l.yaml    # Force large"
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
    local provided_values_file="${2:-}"
    
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
    
    # Try to detect cluster size from bloom configmap
    local cluster_size=""
    if kubectl get configmap bloom -n default >/dev/null 2>&1; then
        cluster_size=$(kubectl get configmap bloom -n default -o jsonpath='{.data.CLUSTER_SIZE}' 2>/dev/null || echo "")
        
        if [ -n "$cluster_size" ]; then
            echo "Detected cluster size from bloom configmap: $cluster_size" >&2
            
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
                    echo "WARNING: Unknown cluster size '$cluster_size' in bloom configmap, defaulting to small" >&2
                    echo "small values.yaml"
                    ;;
            esac
            return 0
        fi
    else
        echo "INFO: bloom configmap not found, defaulting to small cluster" >&2
    fi
    
    # Default to small
    echo "small values.yaml"
}

# Parse cluster configuration
CLUSTER_CONFIG="$(detect_cluster_config "$@")"
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
echo "✓ Values files: $VALUES_FILES"

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