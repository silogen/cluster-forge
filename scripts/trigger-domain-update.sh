#!/bin/bash

DOMAIN="${1:-}"
FORCE="${2:-false}"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <new-domain> [force]"
    echo ""
    echo "Examples:"
    echo "  $0 new-domain.com"
    echo "  $0 new-domain.com force  # Skip confirmation"
    echo ""
    echo "This script triggers a manual domain update in the cluster-forge system."
    echo "It supports multiple trigger mechanisms for immediate updates without waiting for ArgoCD polling."
    exit 1
fi

echo "Triggering manual domain update to: $DOMAIN"

# Function to check if kubectl is available and connected
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        echo "ERROR: kubectl is not connected to a cluster"
        exit 1
    fi
    
    echo "✓ kubectl is available and connected"
}

# Function to validate the domain format
validate_domain() {
    local domain="$1"
    
    # Basic domain validation
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo "ERROR: Invalid domain format: $domain"
        exit 1
    fi
    
    echo "✓ Domain format is valid: $domain"
}

# Function to get current domain
get_current_domain() {
    local current_domain=""
    
    if kubectl get configmap current-domain-config -n cf-system &> /dev/null; then
        current_domain=$(kubectl get configmap current-domain-config -n cf-system -o jsonpath='{.data.domain}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$current_domain" ]; then
        echo "Current domain: $current_domain"
        return 0
    else
        echo "Current domain: Not set or unknown"
        return 1
    fi
}

# Function to confirm the update
confirm_update() {
    local old_domain="$1"
    local new_domain="$2"
    local force="$3"
    
    if [ "$force" = "force" ] || [ "$force" = "true" ]; then
        echo "Force mode enabled, skipping confirmation"
        return 0
    fi
    
    echo ""
    echo "Domain Update Confirmation:"
    echo "  From: ${old_domain:-"(unknown)"}"
    echo "  To:   $new_domain"
    echo ""
    echo -n "Are you sure you want to proceed? [y/N]: "
    read -r response
    
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            echo "Update cancelled"
            exit 0
            ;;
    esac
}

# Function to trigger update via ArgoCD application refresh
trigger_via_argocd() {
    local domain="$1"
    
    echo "Method 1: Triggering via ArgoCD application refresh..."
    
    if ! kubectl get application cluster-forge -n argocd &> /dev/null; then
        echo "WARNING: cluster-forge application not found in argocd namespace"
        return 1
    fi
    
    # Patch the application to trigger immediate sync
    if kubectl patch application cluster-forge -n argocd -p='{"operation":{"sync":{"prune":true}}}' --type=merge; then
        echo "✓ ArgoCD application refresh triggered"
        return 0
    else
        echo "ERROR: Failed to trigger ArgoCD application refresh"
        return 1
    fi
}

# Function to trigger update via direct annotation
trigger_via_annotation() {
    local domain="$1"
    
    echo "Method 2: Triggering via application annotation..."
    
    if ! kubectl get application cluster-forge -n argocd &> /dev/null; then
        echo "WARNING: cluster-forge application not found in argocd namespace"
        return 1
    fi
    
    # Add manual trigger annotations
    if kubectl annotate application cluster-forge -n argocd \
        manual-domain-update="$(date +%s)" \
        manual-domain-target="$domain" \
        --overwrite; then
        echo "✓ Manual domain update annotation added"
        return 0
    else
        echo "ERROR: Failed to add manual domain update annotation"
        return 1
    fi
}

# Function to trigger update via direct job creation
trigger_via_job() {
    local domain="$1"
    
    echo "Method 3: Triggering via direct job creation..."
    
    # Create a manual domain update job
    local job_name="domain-update-manual-$(date +%s)"
    
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: cf-system
  labels:
    app: domain-updater
    trigger-type: manual
    created-by: cli-script
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 1800
  template:
    metadata:
      labels:
        app: domain-updater
        job: $job_name
    spec:
      restartPolicy: Never
      containers:
      - name: domain-updater
        image: ghcr.io/silogen/cluster-tool:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          echo "Manual domain update job started"
          echo "Target domain: $domain"
          echo "Updating current domain ConfigMap..."
          kubectl create configmap current-domain-config --from-literal=domain="$domain" -n cf-system --dry-run=client -o yaml | kubectl apply -f -
          echo "Triggering ArgoCD refresh..."
          kubectl patch application cluster-forge -n argocd -p='{"operation":{"sync":{"prune":true}}}' --type=merge || true
          echo "Manual domain update job completed"
        env:
        - name: NEW_DOMAIN
          value: "$domain"
        - name: TRIGGER_TYPE
          value: "manual"
EOF

    if [ $? -eq 0 ]; then
        echo "✓ Manual domain update job created: $job_name"
        echo ""
        echo "Monitor the job with:"
        echo "  kubectl logs -f job/$job_name -n cf-system"
        echo "  kubectl get job $job_name -n cf-system"
        return 0
    else
        echo "ERROR: Failed to create manual domain update job"
        return 1
    fi
}

# Function to wait and monitor the update
monitor_update() {
    echo ""
    echo "Monitoring update progress..."
    echo "Press Ctrl+C to stop monitoring (update will continue in background)"
    echo ""
    
    local timeout=300  # 5 minutes
    local elapsed=0
    local interval=10
    
    while [ $elapsed -lt $timeout ]; do
        echo "=== Update Status (${elapsed}s elapsed) ==="
        
        # Check ArgoCD application status
        if kubectl get application cluster-forge -n argocd &> /dev/null; then
            local sync_status=$(kubectl get application cluster-forge -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
            local health_status=$(kubectl get application cluster-forge -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
            echo "ArgoCD cluster-forge - Sync: $sync_status, Health: $health_status"
        fi
        
        # Check for recent domain update jobs
        local recent_jobs=$(kubectl get jobs -n cf-system -l app=domain-updater --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$recent_jobs" ]; then
            local job_status=$(kubectl get job "$recent_jobs" -n cf-system -o jsonpath='{.status.conditions[-1:].type}' 2>/dev/null || echo "Unknown")
            echo "Latest domain update job: $recent_jobs - Status: $job_status"
        fi
        
        echo ""
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "Monitoring timeout reached. Check manually with:"
    echo "  kubectl get application cluster-forge -n argocd"
    echo "  kubectl get jobs -n cf-system -l app=domain-updater"
}

# Function to display status and next steps
display_status() {
    local domain="$1"
    
    echo ""
    echo "=========================================="
    echo "Domain Update Trigger Summary"
    echo "=========================================="
    echo "Target Domain: $domain"
    echo "Triggered at: $(date)"
    echo ""
    echo "The domain update process has been initiated. Here's what happens next:"
    echo ""
    echo "1. ArgoCD will detect the changes and sync applications"
    echo "2. Domain configurations will be updated across all components"
    echo "3. Ingress resources and certificates will be regenerated"
    echo "4. Applications will be restarted as needed"
    echo ""
    echo "Monitor progress with these commands:"
    echo "  kubectl get application cluster-forge -n argocd"
    echo "  kubectl get jobs -n cf-system -l app=domain-updater"
    echo "  kubectl get events -n cf-system --sort-by='.lastTimestamp'"
    echo ""
    echo "Note: Complete domain propagation may require external DNS updates."
    echo "=========================================="
}

# Main execution
main() {
    echo "=========================================="
    echo "Cluster-Forge Manual Domain Update Tool"
    echo "=========================================="
    
    # Validation steps
    check_kubectl
    validate_domain "$DOMAIN"
    
    # Get current domain info
    get_current_domain
    local current_domain=$(kubectl get configmap current-domain-config -n cf-system -o jsonpath='{.data.domain}' 2>/dev/null || echo "")
    
    # Confirm the update
    confirm_update "$current_domain" "$DOMAIN" "$FORCE"
    
    echo ""
    echo "Starting domain update process..."
    
    # Try multiple trigger methods
    local success=false
    
    if trigger_via_argocd "$DOMAIN"; then
        success=true
    elif trigger_via_annotation "$DOMAIN"; then
        success=true
    elif trigger_via_job "$DOMAIN"; then
        success=true
    else
        echo ""
        echo "ERROR: All trigger methods failed!"
        echo "Please check cluster connectivity and permissions."
        exit 1
    fi
    
    if [ "$success" = "true" ]; then
        display_status "$DOMAIN"
        
        # Ask if user wants to monitor
        echo -n "Would you like to monitor the update progress? [y/N]: "
        read -r monitor_response
        
        case "$monitor_response" in
            [yY][eE][sS]|[yY])
                monitor_update
                ;;
            *)
                echo "Update triggered successfully. Monitor manually if needed."
                ;;
        esac
    fi
}

# Execute main function
main "$@"