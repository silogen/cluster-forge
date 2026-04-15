#!/bin/bash
# Cluster Cleanup Script for Cluster Forge
# This script removes all cluster-forge resources to enable a clean reinstall

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
DRY_RUN=false
KEEP_CRDS=true
KEEP_NAMESPACES=true
FORCE=false
VERBOSE=false

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Clean up cluster-forge installation to prepare for a fresh install.

OPTIONS:
    -d, --dry-run           Show what would be deleted without actually deleting
    -f, --force             Skip confirmation prompts
    --delete-crds           Also delete CRDs (use with caution)
    --delete-namespaces     Delete all cluster-forge namespaces
    -v, --verbose           Verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Dry run to see what will be deleted
    $0 --dry-run

    # Clean cluster keeping CRDs and namespaces
    $0

    # Full cleanup including CRDs and namespaces
    $0 --delete-crds --delete-namespaces --force

    # Interactive cleanup with verbose output
    $0 -v

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --delete-crds)
            KEEP_CRDS=false
            shift
            ;;
        --delete-namespaces)
            KEEP_NAMESPACES=false
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Function to execute kubectl command
execute_cmd() {
    local cmd="$1"
    local description="$2"
    
    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY-RUN] Would execute: $cmd"
        return 0
    fi
    
    if [ "$VERBOSE" = true ]; then
        print_info "Executing: $cmd"
    else
        print_info "$description"
    fi
    
    eval "$cmd" || {
        print_warning "Command failed (may be already deleted): $cmd"
        return 0
    }
}

# Function to confirm action
confirm() {
    if [ "$FORCE" = true ]; then
        return 0
    fi
    
    read -p "$(echo -e ${YELLOW}[CONFIRM]${NC} $1 \(y/N\): )" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operation cancelled."
        exit 0
    fi
}

# Display banner
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Cluster Forge - Cluster Cleanup Script            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl not found. Please install kubectl first."
    exit 1
fi

# Check cluster connectivity
print_info "Checking cluster connectivity..."
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to cluster. Please check your kubeconfig."
    exit 1
fi
print_success "Connected to cluster: $(kubectl config current-context)"
echo

# Show current cluster state
print_info "Current cluster-forge resources:"
kubectl get applications -n argocd 2>/dev/null | grep -E "^(cluster-forge|cluster-apps)" || print_warning "No ArgoCD applications found"
echo

# Confirm cleanup
if [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}WARNING: This will delete the following:${NC}"
    echo "  - ArgoCD Applications (cluster-forge, cluster-apps, and all managed apps)"
    echo "  - ArgoCD itself (namespace, deployments, configurations)"
    echo "  - All managed applications and resources"
    echo "  - Persistent Volume Claims (data will be lost!)"
    if [ "$KEEP_CRDS" = false ]; then echo "  - Custom Resource Definitions (CRDs)"; fi
    if [ "$KEEP_NAMESPACES" = false ]; then echo "  - All cluster-forge namespaces (including argocd)"; fi
    echo
    confirm "Are you sure you want to proceed with cleanup?"
    echo
fi

# Step 1: Delete ArgoCD Applications
print_info "Step 1: Deleting ArgoCD Applications..."
execute_cmd "kubectl delete application cluster-apps -n argocd --wait=false 2>/dev/null" "Deleting cluster-apps application"
execute_cmd "kubectl delete application cluster-forge -n argocd --wait=false 2>/dev/null" "Deleting cluster-forge application"

if [ "$DRY_RUN" = false ]; then
    print_info "Waiting for ArgoCD to process deletions (30 seconds)..."
    sleep 30
fi

# Step 2: Force delete stuck applications (remove finalizers)
print_info "Step 2: Cleaning up stuck applications..."
execute_cmd "kubectl patch application cluster-apps -n argocd -p '{\"metadata\":{\"finalizers\":null}}' --type=merge 2>/dev/null" "Removing cluster-apps finalizers"
execute_cmd "kubectl patch application cluster-forge -n argocd -p '{\"metadata\":{\"finalizers\":null}}' --type=merge 2>/dev/null" "Removing cluster-forge finalizers"

# Step 3: Delete cluster-forge Helm releases
print_info "Step 3: Deleting Helm releases..."
if command -v helm &> /dev/null; then
    execute_cmd "helm uninstall cluster-forge -n argocd 2>/dev/null" "Uninstalling cluster-forge helm release"
else
    print_warning "Helm not found, skipping Helm release cleanup"
fi

# Step 4: Get list of cluster-forge namespaces
print_info "Step 4: Identifying cluster-forge namespaces..."

# Get namespaces from ArgoCD applications
ARGOCD_NAMESPACES=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name != "argocd") | .spec.destination.namespace' | sort -u || echo "")

# Also check for cf- and cluster- prefixed namespaces
PREFIX_NAMESPACES=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -E '^cf-|^cluster-' || echo "")

# Combine and deduplicate (exclude only system namespaces, include argocd)
CF_NAMESPACES=$(echo -e "$ARGOCD_NAMESPACES\n$PREFIX_NAMESPACES" | sort -u | grep -v -E '^(kube-system|kube-public|kube-node-lease|default)$' || echo "")

# Add argocd namespace explicitly since cluster-forge installs it
if kubectl get namespace argocd &>/dev/null; then
    CF_NAMESPACES=$(echo -e "$CF_NAMESPACES\nargocd" | sort -u)
fi

# Step 4a: Delete webhooks that might block deletions
print_info "Step 4a: Removing webhooks that might block deletions..."
execute_cmd "kubectl delete validatingwebhookconfigurations -l app.kubernetes.io/part-of=cluster-forge 2>/dev/null" "Deleting validating webhooks"
execute_cmd "kubectl delete mutatingwebhookconfigurations -l app.kubernetes.io/part-of=cluster-forge 2>/dev/null" "Deleting mutating webhooks"

# Delete common webhooks by name patterns
if [ "$DRY_RUN" = false ]; then
    kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'kyverno|kserve|kueue|cert-manager|cnpg|minio' | xargs -r kubectl delete --wait=false 2>/dev/null || true
    kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'kyverno|kserve|kueue|cert-manager|cnpg|minio' | xargs -r kubectl delete --wait=false 2>/dev/null || true
fi

# Step 4b: Delete operator-managed custom resources
print_info "Step 4b: Deleting operator-managed custom resources..."

# Delete MinIO Tenants (removes finalizers first)
if [ "$DRY_RUN" = false ]; then
    kubectl get tenants.minio.min.io -A -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read ns name; do
            kubectl patch tenant.minio.min.io $name -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    kubectl delete tenants.minio.min.io --all -A --wait=false 2>/dev/null || true
fi

# Delete CNPG Clusters
if [ "$DRY_RUN" = false ]; then
    kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read ns name; do
            kubectl patch cluster.postgresql.cnpg.io $name -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    kubectl delete clusters.postgresql.cnpg.io --all -A --wait=false 2>/dev/null || true
fi

# Delete RabbitMQ Clusters
if [ "$DRY_RUN" = false ]; then
    kubectl get rabbitmqclusters.rabbitmq.com -A -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read ns name; do
            kubectl patch rabbitmqcluster.rabbitmq.com $name -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    kubectl delete rabbitmqclusters.rabbitmq.com --all -A --wait=false 2>/dev/null || true
fi

if [ -n "$CF_NAMESPACES" ]; then
    # Filter to only existing namespaces
    EXISTING_NAMESPACES=""
    for ns in $CF_NAMESPACES; do
        if kubectl get namespace $ns &>/dev/null; then
            EXISTING_NAMESPACES="$EXISTING_NAMESPACES $ns"
        fi
    done
    
    if [ -z "$EXISTING_NAMESPACES" ]; then
        print_warning "No existing cluster-forge namespaces found"
    else
        print_info "Found cluster-forge namespaces:"
        echo "$EXISTING_NAMESPACES" | tr ' ' '\n' | sed 's/^/  - /'
        
        # Step 5: Delete resources in namespaces
        print_info "Step 5: Cleaning up resources in namespaces..."
        for ns in $EXISTING_NAMESPACES; do
            print_info "Cleaning namespace: $ns"
            
            # Remove finalizers from everything first
            if [ "$DRY_RUN" = false ]; then
                for resource_type in pods deployments statefulsets daemonsets jobs cronjobs replicasets services configmaps secrets pvc; do
                    kubectl get $resource_type -n $ns -o name 2>/dev/null | \
                        xargs -I {} kubectl patch {} -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
                done
            fi
            
            # Delete all workloads (non-blocking)
            execute_cmd "kubectl delete deployments,statefulsets,daemonsets,replicasets,jobs,cronjobs --all -n $ns --grace-period=0 --force --wait=false 2>/dev/null" "Deleting workloads in $ns"
            
            # Delete pods directly (non-blocking)
            execute_cmd "kubectl delete pods --all -n $ns --grace-period=0 --force --wait=false 2>/dev/null" "Deleting pods in $ns"
            
            # Delete services and endpoints
            execute_cmd "kubectl delete services,endpoints --all -n $ns --wait=false 2>/dev/null" "Deleting services in $ns"
            
            # Delete PVCs (non-blocking)
            execute_cmd "kubectl delete pvc --all -n $ns --grace-period=0 --force --wait=false 2>/dev/null" "Deleting PVCs in $ns"
            
            # Delete everything else
            execute_cmd "kubectl delete all --all -n $ns --grace-period=0 --force --wait=false 2>/dev/null" "Deleting remaining resources in $ns"
        done
        
        # Wait a bit for deletions to process
        if [ "$DRY_RUN" = false ]; then
            print_info "Waiting for resources to delete (10 seconds)..."
            sleep 10
        fi
        
        # Step 5a: Force cleanup of terminating pods
        print_info "Step 5a: Cleaning up terminating pods..."
        if [ "$DRY_RUN" = false ]; then
            for ns in $EXISTING_NAMESPACES; do
                kubectl get pods -n $ns --field-selector=metadata.deletionTimestamp!='' -o name 2>/dev/null | \
                    xargs -I {} kubectl patch {} -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
                kubectl get pods -n $ns --field-selector=metadata.deletionTimestamp!='' -o name 2>/dev/null | \
                    xargs -r kubectl delete -n $ns --grace-period=0 --force 2>/dev/null || true
            done
        fi
        
        CF_NAMESPACES="$EXISTING_NAMESPACES"
    fi
    
    # Step 6: Delete namespaces
    if [ "$KEEP_NAMESPACES" = false ]; then
        print_info "Step 6: Deleting namespaces..."
        for ns in $CF_NAMESPACES; do
            # Remove namespace finalizers first
            if [ "$DRY_RUN" = false ]; then
                kubectl patch namespace $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            fi
            execute_cmd "kubectl delete namespace $ns --grace-period=0 --force --wait=false 2>/dev/null" "Deleting namespace $ns"
        done
        
        # Force remove stuck namespaces
        if [ "$DRY_RUN" = false ]; then
            print_info "Removing stuck namespace finalizers..."
            sleep 10
            for ns in $CF_NAMESPACES; do
                # Final force cleanup via API
                kubectl get namespace $ns -o json 2>/dev/null | \
                    jq '.spec.finalizers = []' | \
                    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
                
                # Also try direct patch
                kubectl patch namespace $ns -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
        fi
    else
        print_info "Step 6: Keeping namespaces (use --delete-namespaces to remove)"
    fi
else
    print_warning "No cluster-forge namespaces found"
fi

# Step 7: Delete CRDs (optional)
if [ "$KEEP_CRDS" = false ]; then
    print_info "Step 7: Deleting Custom Resource Definitions..."
    
    # Remove CRD finalizers first
    if [ "$DRY_RUN" = false ]; then
        kubectl get crd -o name 2>/dev/null | \
            grep -iE 'kyverno|kserve|kueue|cnpg|kedify|keda|appwrapper|kaiwo|aim|gateway' | \
            xargs -I {} kubectl patch {} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    fi
    
    execute_cmd "kubectl delete crd -l app.kubernetes.io/part-of=cluster-forge --wait=false 2>/dev/null" "Deleting cluster-forge CRDs"
    
    # Delete common CRDs by pattern
    if [ "$DRY_RUN" = false ]; then
        kubectl get crd -o name 2>/dev/null | \
            grep -iE 'kyverno|kserve|kueue|cnpg|kedify|keda|appwrapper|kaiwo|aim|gateway' | \
            xargs -r kubectl delete --wait=false 2>/dev/null || true
    fi
else
    print_info "Step 7: Keeping CRDs (use --delete-crds to remove)"
fi

# Step 8: Clean up any remaining cluster roles and bindings
print_info "Step 8: Cleaning up cluster-level resources..."
execute_cmd "kubectl delete clusterrole -l app.kubernetes.io/part-of=cluster-forge --wait=false 2>/dev/null" "Deleting cluster-forge ClusterRoles"
execute_cmd "kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=cluster-forge --wait=false 2>/dev/null" "Deleting cluster-forge ClusterRoleBindings"

# Step 9: Clean up ArgoCD applications and resources
print_info "Step 9: Cleaning up ArgoCD applications and resources..."

# Remove finalizers from ALL ArgoCD applications (including argocd itself)
if [ "$DRY_RUN" = false ]; then
    kubectl get applications -n argocd -o name 2>/dev/null | \
        xargs -I {} kubectl patch {} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
fi

# Delete all ArgoCD applications
execute_cmd "kubectl delete applications --all -n argocd --wait=false 2>/dev/null" "Deleting all ArgoCD applications"

# Clean up AppProjects
execute_cmd "kubectl delete appprojects --all -n argocd --wait=false 2>/dev/null" "Deleting all AppProjects"

# Delete ArgoCD deployment and resources in argocd namespace
if [ "$DRY_RUN" = false ]; then
    print_info "Cleaning up ArgoCD deployment..."
    kubectl delete deployments,statefulsets,services --all -n argocd --wait=false 2>/dev/null || true
fi

# Summary
echo
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Cleanup Complete!                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo

if [ "$DRY_RUN" = true ]; then
    print_warning "This was a DRY RUN. No resources were actually deleted."
    print_info "Run without --dry-run to perform actual cleanup."
else
    print_success "Cluster cleanup completed successfully!"
    print_info "You can now perform a fresh installation of cluster-forge."
    echo
    print_info "Verify cleanup with:"
    echo "  kubectl get applications -n argocd"
    echo "  kubectl get namespaces | grep -E '^cf-|^cluster-'"
    echo "  kubectl get pvc -A"
fi

echo
print_info "To perform a fresh install, run:"
echo "  helm install cluster-forge ./root -n argocd -f ./root/values_small.yaml"
echo
