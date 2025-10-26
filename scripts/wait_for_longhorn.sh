#!/usr/bin/env bash

#######################################
# Wait for Longhorn to be ready
# This script performs comprehensive readiness checks for Longhorn storage system
# before proceeding with cluster bootstrap operations.
#
# Checks performed:
#   1. Longhorn pods are running
#   2. Longhorn nodes are ready and schedulable
#   3. StorageClass is present and set as default
#   4. Storage provisioning works via test PVC
#
# Globals:
#   MAX_RETRIES - Maximum number of retry attempts (default: 60)
#   RETRY_DELAY - Delay between retries in seconds (default: 10)
#   LONGHORN_NAMESPACE - Namespace where Longhorn is deployed (default: longhorn)
#
# Returns:
#   0 on success, 1 on failure
#######################################

set -euo pipefail

# Configuration
MAX_RETRIES="${MAX_RETRIES:-60}"
RETRY_DELAY="${RETRY_DELAY:-10}"
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/waitForLonghorn.log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#######################################
# Log message with timestamp
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message
#######################################
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

#######################################
# Check if kubectl is available
#######################################
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found. Please install kubectl."
        return 1
    fi
    log_info "kubectl is available"
    return 0
}

#######################################
# Check if Longhorn namespace exists
#######################################
check_namespace() {
    log_info "Checking if Longhorn namespace '${LONGHORN_NAMESPACE}' exists..."
    
    if ! kubectl get namespace "${LONGHORN_NAMESPACE}" &> /dev/null; then
        log_error "Longhorn namespace '${LONGHORN_NAMESPACE}' does not exist"
        return 1
    fi
    
    log_success "Longhorn namespace '${LONGHORN_NAMESPACE}' exists"
    return 0
}

#######################################
# Wait for Longhorn pods to be ready
# Checks: longhorn-manager, longhorn-driver-deployer, longhorn-ui,
#         CSI components, and installation daemonsets
#######################################
wait_for_longhorn_pods() {
    log_info "Waiting for Longhorn pods to be ready..."
    
    local required_pod_patterns=(
        "longhorn-manager"
        "longhorn-driver-deployer"
        "csi-attacher"
        "csi-provisioner"
        "csi-resizer"
        "csi-snapshotter"
    )
    
    local optional_pod_patterns=(
        "longhorn-ui"
        "longhorn-csi-plugin"
        "engine-image"
    )
    
    for ((i=1; i<=MAX_RETRIES; i++)); do
        log_info "Attempt $i/$MAX_RETRIES: Checking Longhorn pods..."
        
        local all_ready=true
        local pod_status
        pod_status=$(kubectl get pods -n "${LONGHORN_NAMESPACE}" 2>&1) || {
            log_warn "Failed to get pods, retrying..."
            all_ready=false
        }
        
        if [[ "$all_ready" == "true" ]]; then
            # Check required pods
            for pattern in "${required_pod_patterns[@]}"; do
                local pod_count
                pod_count=$(echo "$pod_status" | grep -c "^${pattern}" || true)
                
                if [[ $pod_count -eq 0 ]]; then
                    log_warn "No pods matching pattern '${pattern}' found"
                    all_ready=false
                    continue
                fi
                
                # Check if all pods matching this pattern are Running or Completed
                local not_ready
                not_ready=$(echo "$pod_status" | grep "^${pattern}" | grep -v -E "Running|Completed" || true)
                
                if [[ -n "$not_ready" ]]; then
                    log_warn "Some ${pattern} pods are not ready:"
                    echo "$not_ready" | while read -r line; do
                        log_warn "  $line"
                    done
                    all_ready=false
                fi
            done
            
            # Check for installation daemonsets (should be Completed or Running)
            local installation_pods
            installation_pods=$(echo "$pod_status" | grep -E "longhorn-(iscsi|nfs)-installation" || true)
            if [[ -n "$installation_pods" ]]; then
                local not_ready_installation
                not_ready_installation=$(echo "$installation_pods" | grep -v -E "Running|Completed" || true)
                if [[ -n "$not_ready_installation" ]]; then
                    log_warn "Some installation pods are not ready:"
                    echo "$not_ready_installation" | while read -r line; do
                        log_warn "  $line"
                    done
                    all_ready=false
                fi
            fi
        fi
        
        if [[ "$all_ready" == "true" ]]; then
            log_success "All required Longhorn pods are ready"
            # Display pod summary
            kubectl get pods -n "${LONGHORN_NAMESPACE}" | tee -a "${LOG_FILE}"
            return 0
        fi
        
        if [[ $i -lt $MAX_RETRIES ]]; then
            log_info "Waiting ${RETRY_DELAY} seconds before retry..."
            sleep "$RETRY_DELAY"
        fi
    done
    
    log_error "Timeout waiting for Longhorn pods to be ready after $MAX_RETRIES attempts"
    log_error "Current pod status:"
    kubectl get pods -n "${LONGHORN_NAMESPACE}" | tee -a "${LOG_FILE}"
    return 1
}

#######################################
# Wait for Longhorn nodes to be ready and schedulable
#######################################
wait_for_longhorn_nodes() {
    log_info "Waiting for Longhorn nodes to be ready and schedulable..."
    
    for ((i=1; i<=MAX_RETRIES; i++)); do
        log_info "Attempt $i/$MAX_RETRIES: Checking Longhorn nodes..."
        
        local nodes_output
        if ! nodes_output=$(kubectl get nodes.longhorn.io -n "${LONGHORN_NAMESPACE}" 2>&1); then
            log_warn "Failed to get Longhorn nodes (CRD may not be ready yet), retrying..."
            if [[ $i -lt $MAX_RETRIES ]]; then
                sleep "$RETRY_DELAY"
            fi
            continue
        fi
        
        # Check if we have at least one node
        local node_count
        node_count=$(echo "$nodes_output" | grep -c -v "^NAME" || true)
        
        if [[ $node_count -eq 0 ]]; then
            log_warn "No Longhorn nodes found yet"
            if [[ $i -lt $MAX_RETRIES ]]; then
                sleep "$RETRY_DELAY"
            fi
            continue
        fi
        
        # Check for ready and schedulable nodes
        local ready_schedulable_count
        ready_schedulable_count=$(kubectl get nodes.longhorn.io -n "${LONGHORN_NAMESPACE}" -o json 2>/dev/null | \
            jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | select(.spec.allowScheduling==true) | .metadata.name' | \
            wc -l || echo "0")
        
        if [[ $ready_schedulable_count -gt 0 ]]; then
            log_success "Found ${ready_schedulable_count} ready and schedulable Longhorn node(s)"
            kubectl get nodes.longhorn.io -n "${LONGHORN_NAMESPACE}" | tee -a "${LOG_FILE}"
            return 0
        fi
        
        log_warn "No ready and schedulable Longhorn nodes found yet"
        
        if [[ $i -lt $MAX_RETRIES ]]; then
            log_info "Waiting ${RETRY_DELAY} seconds before retry..."
            sleep "$RETRY_DELAY"
        fi
    done
    
    log_error "Timeout waiting for Longhorn nodes to be ready and schedulable after $MAX_RETRIES attempts"
    log_error "Current node status:"
    kubectl get nodes.longhorn.io -n "${LONGHORN_NAMESPACE}" | tee -a "${LOG_FILE}"
    return 1
}

#######################################
# Check if Longhorn StorageClass exists and is default
#######################################
check_storageclass() {
    log_info "Checking Longhorn StorageClass..."
    
    for ((i=1; i<=MAX_RETRIES; i++)); do
        log_info "Attempt $i/$MAX_RETRIES: Checking StorageClass..."
        
        # Get all StorageClasses
        local sc_output
        if ! sc_output=$(kubectl get storageclass 2>&1); then
            log_warn "Failed to get StorageClasses, retrying..."
            if [[ $i -lt $MAX_RETRIES ]]; then
                sleep "$RETRY_DELAY"
            fi
            continue
        fi
        
        # Check for any StorageClass with Longhorn provisioner (driver.longhorn.io)
        local longhorn_sc_count
        longhorn_sc_count=$(kubectl get storageclass -o json 2>/dev/null | \
            jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | .metadata.name' | \
            wc -l || echo "0")
        
        if [[ $longhorn_sc_count -eq 0 ]]; then
            log_warn "No StorageClasses with Longhorn provisioner (driver.longhorn.io) found yet"
            if [[ $i -lt $MAX_RETRIES ]]; then
                sleep "$RETRY_DELAY"
            fi
            continue
        fi
        
        log_success "Found ${longhorn_sc_count} StorageClass(es) with Longhorn provisioner"
        
        # Check if there's a default StorageClass with Longhorn provisioner
        local default_longhorn_sc
        default_longhorn_sc=$(kubectl get storageclass -o json 2>/dev/null | \
            jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true" or .metadata
.annotations["storageclass.beta.kubernetes.io/is-default-class"]=="true") | .metadata.name' | \
            head -n 1 || echo "")
        
        if [[ -n "$default_longhorn_sc" ]]; then
            log_success "Default StorageClass '${default_longhorn_sc}' uses Longhorn provisioner"
        else
            log_warn "No default StorageClass with Longhorn provisioner found"
            log_warn "Available Longhorn StorageClasses:"
            kubectl get storageclass -o json 2>/dev/null | \
                jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | .metadata.name' | \
                while read -r sc; do
                    log_warn "  - ${sc}"
                done
        fi
        
        # Display all StorageClasses for reference
        log_info "All StorageClasses:"
        kubectl get storageclass | tee -a "${LOG_FILE}"
        return 0
    done
    
    log_error "Timeout waiting for Longhorn StorageClass after $MAX_RETRIES attempts"
    kubectl get storageclass | tee -a "${LOG_FILE}"
    return 1
}

#######################################
# Test storage provisioning with a test PVC
#######################################
test_storage_provisioning() {
    log_info "Testing storage provisioning with test PVC..."
    
    local test_pvc_name="longhorn-test-pvc-$$"
    local test_namespace="${LONGHORN_NAMESPACE}"
    local cleanup_needed=false
    
    # Cleanup function
    cleanup_test_pvc() {
        if [[ "${cleanup_needed:-false}" == "true" ]]; then
            log_info "Cleaning up test PVC..."
            kubectl delete pvc "${test_pvc_name}" -n "${test_namespace}" --ignore-not-found=true &> /dev/null || true
        fi
    }
    
    # Register cleanup on exit
    trap cleanup_test_pvc EXIT
    
    # Create test PVC
    log_info "Creating test PVC '${test_pvc_name}'..."

    # Find the default Longhorn StorageClass or use 'default' as fallback
    local storage_class
    storage_class=$(kubectl get storageclass -o json 2>/dev/null | \
        jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"]=="true") | .metadata.name' | \
        head -n 1 || echo "")
    
    if [[ -z "$storage_class" ]]; then
        # If no default found, try to find one named 'default' or 'longhorn'
        storage_class=$(kubectl get storageclass -o json 2>/dev/null | \
            jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | select(.metadata.name=="default" or .metadata.name=="longhorn") | .metadata.name' | \
            head -n 1 || echo "")
    fi
    
    if [[ -z "$storage_class" ]]; then
        # If still not found, just use the first Longhorn StorageClass
        storage_class=$(kubectl get storageclass -o json 2>/dev/null | \
            jq -r '.items[] | select(.provisioner=="driver.longhorn.io") | .metadata.name' | \
            head -n 1 || echo "")
    fi
    
    if [[ -z "$storage_class" ]]; then
        log_error "No Longhorn StorageClass found for testing"
        return 1
    fi
    
    log_info "Using StorageClass '${storage_class}' for test PVC"

    local test_pvc_yaml
    test_pvc_yaml=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${test_pvc_name}
  namespace: ${test_namespace}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${storage_class}
EOF
)
    
    if ! echo "$test_pvc_yaml" | kubectl apply -f - &> /dev/null; then
        log_error "Failed to create test PVC"
        return 1
    fi
    
    cleanup_needed=true
    
    # Wait for PVC to be bound
    log_info "Waiting for test PVC to be bound..."
    
    for ((i=1; i<=MAX_RETRIES; i++)); do
        log_info "Attempt $i/$MAX_RETRIES: Checking PVC status..."
        
        local pvc_status
        pvc_status=$(kubectl get pvc "${test_pvc_name}" -n "${test_namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [[ "$pvc_status" == "Bound" ]]; then
            log_success "Test PVC successfully bound - storage provisioning works!"
            kubectl get pvc "${test_pvc_name}" -n "${test_namespace}" | tee -a "${LOG_FILE}"
            
            # Cleanup
            cleanup_test_pvc
            cleanup_needed=false
            return 0
        elif [[ "$pvc_status" == "Pending" ]]; then
            log_info "PVC is still pending..."
            
            # Show events for debugging
            if [[ $((i % 5)) -eq 0 ]]; then
                log_info "PVC events:"
                kubectl describe pvc "${test_pvc_name}" -n "${test_namespace}" | grep -A 10 "Events:" | tee -a "${LOG_FILE}"
            fi
        else
            log_warn "PVC status: ${pvc_status}"
        fi
        
        if [[ $i -lt $MAX_RETRIES ]]; then
            sleep "$RETRY_DELAY"
        fi
    done
    
    log_error "Timeout waiting for test PVC to be bound after $MAX_RETRIES attempts"
    log_error "PVC details:"
    kubectl describe pvc "${test_pvc_name}" -n "${test_namespace}" | tee -a "${LOG_FILE}"
    
    return 1
}

#######################################
# Main function
#######################################
main() {
    log_info "=========================================="
    log_info "Starting Longhorn readiness check"
    log_info "=========================================="
    log_info "Configuration:"
    log_info "  Max retries: ${MAX_RETRIES}"
    log_info "  Retry delay: ${RETRY_DELAY}s"
    log_info "  Namespace: ${LONGHORN_NAMESPACE}"
    log_info "  Log file: ${LOG_FILE}"
    log_info "=========================================="
    
    # Run all checks
    check_kubectl || exit 1
    check_namespace || exit 1
    wait_for_longhorn_pods || exit 1
    wait_for_longhorn_nodes || exit 1
    check_storageclass || exit 1
    test_storage_provisioning || exit 1
    
    log_success "=========================================="
    log_success "Longhorn is ready!"
    log_success "=========================================="
    
    return 0
}

# Run main function
main "$@"