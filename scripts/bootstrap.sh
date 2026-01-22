#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
DOMAIN="${1:-}"
CLUSTER_SIZE=""
CI_MODE=false
KUBE_VERSION=1.33
LOGFILE=""

# Parse arguments - process flags first, then domain
TEMP_DOMAIN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --ci)
      CI_MODE=true
      shift
      ;;
    --size)
      if [ -z "$2" ]; then
        echo "ERROR: --size requires an argument"
        exit 1
      fi
      CLUSTER_SIZE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 <domain> [--size small|medium|large] [--ci]"
      echo ""
      echo "Arguments:"
      echo "  domain                  Required. Cluster domain (e.g., example.com)"
      echo "  --size SIZE            Optional. Override cluster size detection"
      echo "  --ci                   Optional. CI mode - no interactive prompts"
      echo ""
      echo "Environment detection:"
      echo "  - Reads CLUSTER_SIZE from bloom-config ConfigMap if available"
      echo "  - Validates node count against cluster size requirements"
      echo "  - Uses values.yaml + size-specific overrides (values_medium.yaml, values_large.yaml)"
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1"
      exit 1
      ;;
    *)
      # Non-option argument - should be domain
      if [ -z "$TEMP_DOMAIN" ]; then
        TEMP_DOMAIN="$1"
      else
        echo "ERROR: Multiple domain arguments provided: $TEMP_DOMAIN and $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# Set domain from temp variable
DOMAIN="$TEMP_DOMAIN"

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [--size small|medium|large] [--ci]"
    echo "Use --help for more details"
    exit 1
fi

# Initialize logging
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="${SCRIPT_DIR}/../logs/bootstrap_${TIMESTAMP}.log"
mkdir -p "${SCRIPT_DIR}/../logs"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOGFILE"
    
    # Also echo to console with colors for non-CI mode
    if [ "$CI_MODE" = false ]; then
        case "$level" in
            "INFO") echo "📋 $message" ;;
            "WARN") echo "⚠️  $message" ;;
            "ERROR") echo "❌ $message" ;;
            "SUCCESS") echo "✅ $message" ;;
            *) echo "$message" ;;
        esac
    fi
}

# Cluster size detection and validation
detect_cluster_size() {
    log "INFO" "Detecting cluster size configuration..."
    
    # Try to read from bloom-config ConfigMap first
    if [ -z "$CLUSTER_SIZE" ]; then
        if kubectl get configmap bloom-config -n bloom-system >/dev/null 2>&1; then
            DETECTED_SIZE=$(kubectl get configmap bloom-config -n bloom-system -o jsonpath='{.data.CLUSTER_SIZE}' 2>/dev/null || echo "")
            if [ -n "$DETECTED_SIZE" ]; then
                CLUSTER_SIZE="$DETECTED_SIZE"
                log "INFO" "Cluster size detected from bloom-config: $CLUSTER_SIZE"
            fi
        fi
    fi
    
    # Default to small if not specified
    if [ -z "$CLUSTER_SIZE" ]; then
        CLUSTER_SIZE="small"
        log "INFO" "No cluster size specified, defaulting to: $CLUSTER_SIZE"
    fi
    
    # Validate cluster size value
    case "$CLUSTER_SIZE" in
        small|medium|large)
            log "INFO" "Using cluster size: $CLUSTER_SIZE"
            ;;
        *)
            log "ERROR" "Invalid cluster size: $CLUSTER_SIZE. Must be one of: small, medium, large"
            exit 1
            ;;
    esac
}

# Node validation
validate_cluster_nodes() {
    log "INFO" "Validating cluster nodes against size requirements..."
    
    # Get node information
    local total_nodes
    local control_plane_nodes
    local worker_nodes
    
    total_nodes=$(kubectl get nodes --no-headers | wc -l)
    control_plane_nodes=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/control-plane --ignore-not-found | wc -l)
    worker_nodes=$((total_nodes - control_plane_nodes))
    
    log "INFO" "Cluster topology: ${total_nodes} total nodes (${control_plane_nodes} control-plane, ${worker_nodes} workers)"
    
    # Define requirements
    local min_nodes_small=1
    local min_nodes_medium=1
    local min_nodes_large=4  # 3 CP + 1 worker minimum for HA
    
    local warning=""
    local error=""
    
    case "$CLUSTER_SIZE" in
        small)
            if [ "$total_nodes" -gt 1 ]; then
                warning="Small configuration on multi-node cluster ($total_nodes nodes). Consider using 'medium' or 'large' size."
            fi
            ;;
        medium)
            if [ "$total_nodes" -lt 2 ]; then
                warning="Medium configuration recommended for 2+ nodes (current: $total_nodes nodes)"
            fi
            ;;
        large)
            if [ "$total_nodes" -lt "$min_nodes_large" ]; then
                error="Large configuration requires minimum $min_nodes_large nodes for HA (current: $total_nodes nodes)"
            elif [ "$control_plane_nodes" -lt 3 ] && [ "$total_nodes" -ge 4 ]; then
                warning="Large configuration recommended with 3+ control-plane nodes for HA (current: $control_plane_nodes CP nodes)"
            fi
            ;;
    esac
    
    if [ -n "$error" ]; then
        log "ERROR" "$error"
        if [ "$CI_MODE" = true ]; then
            log "ERROR" "CI mode enabled - exiting due to validation failure"
            exit 1
        else
            echo ""
            echo "❌ Cluster validation failed. Please adjust your cluster size or add more nodes."
            exit 1
        fi
    fi
    
    if [ -n "$warning" ]; then
        log "WARN" "$warning"
        if [ "$CI_MODE" = false ]; then
            echo ""
            read -p "⚠️  Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "INFO" "Bootstrap cancelled by user"
                exit 0
            fi
        fi
    fi
    
    log "SUCCESS" "Cluster validation completed"
}

# Determine values files
get_values_files() {
    local base_values="${SCRIPT_DIR}/../root/values.yaml"
    local size_values=""
    local values_args="-f $base_values"
    
    case "$CLUSTER_SIZE" in
        medium)
            size_values="${SCRIPT_DIR}/../root/values_medium.yaml"
            ;;
        large)
            size_values="${SCRIPT_DIR}/../root/values_large.yaml"
            ;;
        small)
            # Only base values for small
            ;;
    esac
    
    # Check if size-specific values file exists
    if [ -n "$size_values" ] && [ -f "$size_values" ]; then
        values_args="$values_args -f $size_values"
        log "INFO" "Using values files: values.yaml + values_${CLUSTER_SIZE}.yaml"
    else
        if [ "$CLUSTER_SIZE" != "small" ]; then
            log "WARN" "Size-specific values file not found: $size_values, using base values only"
        fi
        log "INFO" "Using values file: values.yaml"
    fi
    
    echo "$values_args"
}

# Helper functions for idempotent operations
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-}"
    
    if [ -n "$namespace" ]; then
        kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1
    else
        kubectl get "$resource_type" "$resource_name" >/dev/null 2>&1
    fi
}

deployment_ready() {
    local deployment="$1"
    local namespace="$2"
    
    if ! resource_exists "deployment" "$deployment" "$namespace"; then
        return 1
    fi
    
    local ready=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    [ "$ready" = "$desired" ] && [ "$ready" != "0" ]
}

statefulset_ready() {
    local statefulset="$1" 
    local namespace="$2"
    
    if ! resource_exists "statefulset" "$statefulset" "$namespace"; then
        return 1
    fi
    
    local ready=$(kubectl get statefulset "$statefulset" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get statefulset "$statefulset" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    [ "$ready" = "$desired" ] && [ "$ready" != "0" ]
}

job_completed() {
    local job="$1"
    local namespace="$2"
    
    if ! resource_exists "job" "$job" "$namespace"; then
        return 1
    fi
    
    local conditions=$(kubectl get job "$job" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    [ "$conditions" = "True" ]
}

# Safe kubectl apply that handles conflicts
safe_kubectl_apply() {
    local manifest="$1"
    echo "$manifest" | kubectl apply -f - --validate=false --force-conflicts --server-side=true 2>/dev/null || {
        log "WARN" "Some resources may already exist, attempting regular apply..."
        echo "$manifest" | kubectl apply -f - --validate=false 2>/dev/null || true
    }
}

# Main bootstrap sequence
main() {
    log "INFO" "Starting Cluster-Forge bootstrap for domain: $DOMAIN"
    log "INFO" "CI Mode: $CI_MODE"
    
    # Detect and validate cluster configuration
    detect_cluster_size
    validate_cluster_nodes
    
    # Display cluster configuration
    case "$CLUSTER_SIZE" in
        small)
            log "INFO" "📱 SMALL CLUSTER: Workstation/Development (1 node, limited resources)"
            ;;
        medium)
            log "INFO" "👥 MEDIUM CLUSTER: Team environment (1-3 nodes, shared resources)"
            ;;
        large)
            log "INFO" "🏭 LARGE CLUSTER: Production scale (4+ nodes, HA control plane)"
            ;;
    esac
    
    if [ "$CI_MODE" = false ]; then
        echo ""
        read -p "🚀 Ready to bootstrap cluster-forge? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Bootstrap cancelled by user"
            exit 0
        fi
    fi
    
    log "INFO" "This is the way! Beginning cluster-forge deployment..."
    
    # Get values file arguments
    VALUES_ARGS=$(get_values_files)
    
    # Create namespaces
    log "INFO" "Creating core namespaces..."
    kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    # ArgoCD bootstrap
    log "INFO" "🚀 Bootstrapping ArgoCD..."

    # Check if ArgoCD is already ready
    if statefulset_ready "argocd-application-controller" "argocd" && \
       deployment_ready "argocd-applicationset-controller" "argocd" && \
       deployment_ready "argocd-redis" "argocd" && \
       deployment_ready "argocd-repo-server" "argocd"; then
        log "SUCCESS" "ArgoCD already deployed and ready"
    else
        # Create temporary merged values file for ArgoCD
        ARGOCD_MERGED_CONFIG="/tmp/bootstrap-argocd-$$.yaml"
        echo "apps:" > "$ARGOCD_MERGED_CONFIG"
        echo "  argocd:" >> "$ARGOCD_MERGED_CONFIG" 
        echo "    valuesObject: {}" >> "$ARGOCD_MERGED_CONFIG"

        # Merge valuesObject from values files with size overrides
        eval "helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --show-only templates/cluster-apps.yaml" | \
            yq '.spec.sources[0].helm.values | fromyaml | .apps.argocd.valuesObject' > /tmp/argocd-values-$$.yaml 2>/dev/null || \
            echo "{}" > /tmp/argocd-values-$$.yaml
        
        yq eval '.apps.argocd.valuesObject = load("/tmp/argocd-values-'$$'.yaml")' "$ARGOCD_MERGED_CONFIG" > "${ARGOCD_MERGED_CONFIG}.tmp"
        mv "${ARGOCD_MERGED_CONFIG}.tmp" "$ARGOCD_MERGED_CONFIG"
        rm -f /tmp/argocd-values-$$.yaml

        log "INFO" "📦 Deploying ArgoCD components..."
        ARGOCD_MANIFEST=$(helm template --release-name argocd ${SCRIPT_DIR}/../sources/argocd/8.3.5 \
          --values <(yq '.apps.argocd.valuesObject' "$ARGOCD_MERGED_CONFIG") \
          --namespace argocd \
          --set global.domain="https://argocd.${DOMAIN}" --kube-version=${KUBE_VERSION})
        
        safe_kubectl_apply "$ARGOCD_MANIFEST"
        rm -f "$ARGOCD_MERGED_CONFIG"

        log "INFO" "⏳ Waiting for ArgoCD components to be ready..."
        kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
        kubectl rollout status deploy/argocd-applicationset-controller -n argocd --timeout=300s
        kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
        kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
        log "SUCCESS" "ArgoCD bootstrap complete"
    fi

    # OpenBao bootstrap
    log "INFO" "🔐 Bootstrapping OpenBao..."

    # Check if OpenBao is already initialized
    if resource_exists "pod" "openbao-0" "cf-openbao" && job_completed "openbao-init-job" "cf-openbao"; then
        log "SUCCESS" "OpenBao already deployed and initialized"
    else
        # Clean up any problematic test pods that might be stuck
        kubectl delete pod openbao-server-test -n cf-openbao --ignore-not-found=true

        # Create temporary merged values file for OpenBao
        OPENBAO_MERGED_CONFIG="/tmp/bootstrap-openbao-$$.yaml"
        echo "apps:" > "$OPENBAO_MERGED_CONFIG"
        echo "  openbao:" >> "$OPENBAO_MERGED_CONFIG"
        echo "    valuesObject: {}" >> "$OPENBAO_MERGED_CONFIG"

        # Merge valuesObject from values files with size overrides
        eval "helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --show-only templates/cluster-apps.yaml" | \
            yq '.spec.sources[0].helm.values | fromyaml | .apps.openbao.valuesObject' > /tmp/openbao-values-$$.yaml 2>/dev/null || \
            echo "{}" > /tmp/openbao-values-$$.yaml
        
        yq eval '.apps.openbao.valuesObject = load("/tmp/openbao-values-'$$'.yaml")' "$OPENBAO_MERGED_CONFIG" > "${OPENBAO_MERGED_CONFIG}.tmp"
        mv "${OPENBAO_MERGED_CONFIG}.tmp" "$OPENBAO_MERGED_CONFIG"
        rm -f /tmp/openbao-values-$$.yaml

        log "INFO" "📦 Deploying OpenBao components..."
        OPENBAO_MANIFEST=$(helm template --release-name openbao ${SCRIPT_DIR}/../sources/openbao/0.18.2 \
          --values <(yq '.apps.openbao.valuesObject' "$OPENBAO_MERGED_CONFIG") \
          --namespace cf-openbao --kube-version=${KUBE_VERSION})
        
        safe_kubectl_apply "$OPENBAO_MANIFEST"
        rm -f "$OPENBAO_MERGED_CONFIG"

        log "INFO" "⏳ Waiting for OpenBao pod to be ready..."
        kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s

        # Handle initialization job idempotently
        if ! job_completed "openbao-init-job" "cf-openbao"; then
            log "INFO" "🔧 Running OpenBao initialization..."
            # Delete existing job if it exists but didn't complete
            kubectl delete job openbao-init-job -n cf-openbao --ignore-not-found=true
            
            INIT_MANIFEST=$(helm template --release-name openbao-init ${SCRIPT_DIR}/init-openbao-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
            safe_kubectl_apply "$INIT_MANIFEST"
            kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao
        fi
        log "SUCCESS" "OpenBao bootstrap complete"
    fi

    # Gitea bootstrap
    log "INFO" "📚 Bootstrapping Gitea..."

    generate_password() {
        openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
    }

    # Check if Gitea is already deployed and initialized
    if deployment_ready "gitea" "cf-gitea" && job_completed "gitea-init-job" "cf-gitea"; then
        log "SUCCESS" "Gitea already deployed and initialized"
    else
        # Create initial-cf-values configmap with merged values
        log "INFO" "📝 Creating initial configuration..."
        eval "helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --show-only templates/cluster-forge.yaml" | \
            yq '.spec.sources[0].helm.valueFiles = ["$values/values.yaml"] | .spec.sources[0].helm.parameters[0].value = "'$DOMAIN'"' | \
            kubectl create configmap initial-cf-values --from-file=/dev/stdin --dry-run=client -o yaml | \
            kubectl apply -n cf-gitea -f -

        # Handle admin credentials idempotently
        if resource_exists "secret" "gitea-admin-credentials" "cf-gitea"; then
            log "INFO" "🔑 Using existing Gitea admin credentials"
        else
            log "INFO" "🔑 Creating new Gitea admin credentials"
            kubectl create secret generic gitea-admin-credentials \
              --namespace=cf-gitea \
              --from-literal=username=silogen-admin \
              --from-literal=password=$(generate_password) \
              --dry-run=client -o yaml | kubectl apply -f -
        fi

        # Create temporary merged values file for Gitea  
        GITEA_MERGED_CONFIG="/tmp/bootstrap-gitea-$$.yaml"
        echo "apps:" > "$GITEA_MERGED_CONFIG"
        echo "  gitea:" >> "$GITEA_MERGED_CONFIG"
        echo "    valuesObject: {}" >> "$GITEA_MERGED_CONFIG"

        # Merge valuesObject from values files with size overrides
        eval "helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --show-only templates/cluster-apps.yaml" | \
            yq '.spec.sources[0].helm.values | fromyaml | .apps.gitea.valuesObject' > /tmp/gitea-values-$$.yaml 2>/dev/null || \
            echo "{}" > /tmp/gitea-values-$$.yaml
        
        yq eval '.apps.gitea.valuesObject = load("/tmp/gitea-values-'$$'.yaml")' "$GITEA_MERGED_CONFIG" > "${GITEA_MERGED_CONFIG}.tmp"
        mv "${GITEA_MERGED_CONFIG}.tmp" "$GITEA_MERGED_CONFIG"
        rm -f /tmp/gitea-values-$$.yaml

        log "INFO" "📦 Deploying Gitea components..."
        GITEA_MANIFEST=$(helm template --release-name gitea ${SCRIPT_DIR}/../sources/gitea/12.3.0 \
          --values <(yq '.apps.gitea.valuesObject' "$GITEA_MERGED_CONFIG") \
          --namespace cf-gitea \
          --set clusterDomain="${DOMAIN}" --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}" --kube-version=${KUBE_VERSION})
        
        safe_kubectl_apply "$GITEA_MANIFEST"
        rm -f "$GITEA_MERGED_CONFIG"

        log "INFO" "⏳ Waiting for Gitea deployment to be ready..."
        kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s

        # Handle initialization job idempotently
        if ! job_completed "gitea-init-job" "cf-gitea"; then
            log "INFO" "🔧 Running Gitea initialization..."
            # Delete existing job if it exists but didn't complete
            kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found=true
            
            INIT_MANIFEST=$(helm template --release-name gitea-init ${SCRIPT_DIR}/init-gitea-job --set domain="${DOMAIN}" --kube-version=${KUBE_VERSION})
            safe_kubectl_apply "$INIT_MANIFEST"
            kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea
        fi
        log "SUCCESS" "Gitea bootstrap complete"
    fi

    # Create cluster-forge app-of-apps
    log "INFO" "🎯 Deploying Cluster-Forge applications..."
    eval "CF_MANIFEST=\$(helm template ${SCRIPT_DIR}/../root $VALUES_ARGS --set global.domain=\"${DOMAIN}\" --kube-version=${KUBE_VERSION})"
    safe_kubectl_apply "$CF_MANIFEST"
    log "SUCCESS" "Cluster-Forge applications deployed"

    log "SUCCESS" "🎉 Bootstrap complete! The fire of the forge eliminates impurities!"
    log "INFO" "🌐 Access your services at:"
    log "INFO" "   ArgoCD:  https://argocd.${DOMAIN}"
    log "INFO" "   Gitea:   https://gitea.${DOMAIN}"
    log "INFO" "   OpenBao: https://openbao.${DOMAIN}"
    log "INFO" ""
    log "INFO" "📋 Full bootstrap log available at: $LOGFILE"
    
    # Final validation summary
    echo ""
    echo "📊 Deployment Summary:"
    echo "   Cluster Size: $CLUSTER_SIZE"
    echo "   Domain: $DOMAIN"
    echo "   Nodes: $(kubectl get nodes --no-headers | wc -l)"
    echo "   Log File: $LOGFILE"
}

# Run main function
main "$@"