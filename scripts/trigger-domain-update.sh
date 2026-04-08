#!/bin/bash
set -euo pipefail

# Simplified Domain Update Script - No Automatic Watching  
# Usage: ./trigger-domain-update.sh <new-domain> <cert-path> <key-path> [old-domain]

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Emoji status indicators
SUCCESS="✅"
WARNING="⚠️"
ERROR="❌"
INFO="ℹ️"
FIRE="🔥"

log_info() {
    echo -e "${BLUE}${INFO} $1${NC}"
}

log_success() {
    echo -e "${GREEN}${SUCCESS} $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}${WARNING} $1${NC}"
}

log_error() {
    echo -e "${RED}${ERROR} $1${NC}"
    exit 1
}

show_usage() {
    echo "Usage: $0 <new-domain> <cert-path> <key-path> [old-domain]"
    echo ""
    echo "Examples:"
    echo "  $0 newdomain.com /path/to/cert.pem /path/to/key.pem"
    echo "  $0 prod.example.com ./certs/tls.crt ./certs/tls.key olddomain.com"
    echo ""
    echo "If old-domain is not provided, it will be automatically extracted from cluster configuration."
    echo "This simplified script eliminates automatic watching and requires manual execution for domain changes."
    echo "🔥 The fire of the forge eliminates impurities - keeping it simple!"
    exit 1
}

validate_domain() {
    local domain=$1
    # Allow multiple subdomain levels with hyphens, but no leading/trailing hyphens in labels
    if ! [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid domain format: $domain"
    fi
    log_success "Domain format validated: $domain"
}

validate_files() {
    local cert_path=$1
    local key_path=$2
    
    if [[ ! -f "$cert_path" ]]; then
        log_error "Certificate file not found: $cert_path"
    fi
    
    if [[ ! -f "$key_path" ]]; then
        log_error "Private key file not found: $key_path"
    fi
    
    log_success "Certificate files validated"
}

check_kubectl() {
    if ! kubectl get namespace kgateway-system &>/dev/null; then
        log_error "Cannot connect to cluster or kgateway-system namespace not found"
    fi
    log_success "Kubernetes connectivity verified"
}

# DNS Integration Functions for cluster-bloom compatibility
detect_cluster_bloom_dns() {
    local dnsmasq_enabled=false
    local fix_dns_used=false
    local current_dns_domain=""
    local systemd_resolved_disabled=false

    # Check for DNSMASQ configuration
    if [[ -f /etc/dnsmasq.d/keycloak.conf ]]; then
        dnsmasq_enabled=true
        current_dns_domain=$(grep "address=/" /etc/dnsmasq.d/keycloak.conf | head -1 | cut -d'/' -f2 2>/dev/null || echo "")
    fi

    # Check for resolv.conf backup (indicates FIX_DNS was used)
    if ls /etc/resolv.conf.pre-dnsmasq-* &>/dev/null; then
        fix_dns_used=true
    fi

    # Check systemd-resolved status
    if ! systemctl is-active systemd-resolved &>/dev/null; then
        systemd_resolved_disabled=true
    fi

    # Export globals for use in other functions
    CLUSTER_BLOOM_DNS_ENABLED="$dnsmasq_enabled"
    CLUSTER_BLOOM_FIX_DNS_USED="$fix_dns_used"
    CURRENT_DNS_DOMAIN="$current_dns_domain"
    SYSTEMD_RESOLVED_DISABLED="$systemd_resolved_disabled"

    # Display status
    echo ""
    echo "🔍 Cluster-Bloom DNS Configuration Status:"
    echo "===========================================" 
    echo "DNSMASQ enabled: $dnsmasq_enabled"
    echo "FIX_DNS was used: $fix_dns_used"
    echo "Current DNS domain: ${current_dns_domain:-none}"
    echo "systemd-resolved disabled: $systemd_resolved_disabled"
    echo ""
}

update_dnsmasq_config() {
    local new_domain=$1
    
    if [[ "$CLUSTER_BLOOM_DNS_ENABLED" != "true" ]]; then
        log_info "DNSMASQ not detected - skipping system DNS update"
        return 0
    fi

    log_info "Updating DNSMASQ configuration for new domain..."
    
    # Create backup
    local backup_file="/etc/dnsmasq.d/keycloak.conf.backup-$(date +%s)"
    if ! cp /etc/dnsmasq.d/keycloak.conf "$backup_file"; then
        log_error "Failed to backup DNSMASQ configuration"
    fi
    
    # Update domain resolution
    if ! sed -i "s|^address=/[^/]*/|address=/$new_domain/|" /etc/dnsmasq.d/keycloak.conf; then
        log_error "Failed to update DNSMASQ configuration"
    fi
    
    # Test configuration
    if ! dnsmasq --test --conf-file=/etc/dnsmasq.d/keycloak.conf; then
        log_error "DNSMASQ configuration test failed - restoring backup"
        cp "$backup_file" /etc/dnsmasq.d/keycloak.conf
        return 1
    fi
    
    # Restart service
    if ! systemctl restart dnsmasq; then
        log_error "Failed to restart DNSMASQ service - restoring backup"
        cp "$backup_file" /etc/dnsmasq.d/keycloak.conf
        systemctl restart dnsmasq
        return 1
    fi
    
    # Wait for service
    sleep 2
    
    # Test DNS resolution
    local retries=3
    for ((i=1; i<=retries; i++)); do
        if nslookup "$new_domain" 127.0.0.1 &>/dev/null && nslookup google.com 127.0.0.1 &>/dev/null; then
            log_success "DNSMASQ configuration updated and tested successfully"
            log_success "DNS resolution: $CURRENT_DNS_DOMAIN → $new_domain"
            return 0
        fi
        log_warning "DNS test failed (attempt $i/$retries)"
        sleep 2
    done
    
    log_error "DNS resolution test failed - rolling back DNSMASQ configuration"
    cp "$backup_file" /etc/dnsmasq.d/keycloak.conf
    systemctl restart dnsmasq
    return 1
}

extract_domain_from_gitea_config() {
    local kc_url
    if kc_url=$(kubectl get configmap gitea-config-script -n cf-gitea -o jsonpath='{.data.configure-gitea\.sh}' 2>/dev/null | grep "KC_URL=" | head -1 | cut -d'=' -f2); then
        # Extract domain from KC_URL like https://kc.plat-ci.silogen.ai
        local domain=$(echo "$kc_url" | sed 's|https://[^.]*\.||' | sed 's|{{.*}}||' | xargs)
        if [[ -n "$domain" && "$domain" != *"Values"* ]]; then
            echo "$domain"
            return 0
        fi
    fi
    return 1
}

get_current_domain() {
    local current_domain
    # Try to get from existing domain config first
    if current_domain=$(kubectl get configmap current-domain-config -n kgateway-system -o jsonpath='{.data.domain}' 2>/dev/null); then
        echo "$current_domain"
        return 0
    fi
    
    # Fallback to extracting from gitea config
    if current_domain=$(extract_domain_from_gitea_config); then
        echo "$current_domain"
        return 0
    fi
    
    echo "unknown"
    return 1
}

update_cluster_values_repo() {
    local new_domain=$1
    local repo_url=$2
    local work_dir="/tmp/cluster-values-$(date +%s)"
    
    log_info "Updating cluster-values repository..."
    
    # Clone repository
    if ! git clone "$repo_url" "$work_dir"; then
        log_error "Failed to clone cluster-values repository: $repo_url"
    fi
    
    cd "$work_dir"
    
    # Update global.domain in values.yaml
    if ! sed -i.bak "s/^\s*domain:\s*.*/  domain: $new_domain/" values.yaml; then
        log_error "Failed to update domain in values.yaml"
    fi
    
    # Check if changes were made
    if ! git diff --quiet; then
        # Commit and push changes
        git config user.name "Simplified Domain Update"
        git config user.email "automation@$new_domain"
        git add values.yaml
        git commit -m "feat: update domain to $new_domain (simplified implementation)"
        
        if ! git push origin main; then
            log_error "Failed to push changes to cluster-values repository"
        fi
        
        log_success "Cluster-values repository updated successfully"
    else
        log_warning "No changes needed in cluster-values repository (domain already set)"
    fi
    
    # Cleanup
    cd - &>/dev/null
    rm -rf "$work_dir"
}

apply_tls_certificates() {
    local new_domain=$1
    local cert_path=$2
    local key_path=$3
    
    log_info "Applying TLS certificates to cluster..."
    
    # Read certificate files
    local cert_content
    local key_content
    cert_content=$(base64 < "$cert_path" | tr -d '\n')
    key_content=$(base64 < "$key_path" | tr -d '\n')
    
    # Create TLS secret
    local secret_name
    secret_name=$(echo "$new_domain" | tr '.' '-')-tls
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
  namespace: kgateway-system
type: kubernetes.io/tls
data:
  tls.crt: $cert_content
  tls.key: $key_content
EOF
    
    log_success "TLS certificates applied"
}

update_domain_configmap() {
    local new_domain=$1
    
    log_info "Updating domain ConfigMap..."
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: current-domain-config
  namespace: kgateway-system
data:
  domain: $new_domain
  updated_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  updated_by: "simplified-domain-change-script"
  method: "manual-execution"
EOF
    
    log_success "Domain ConfigMap updated"
}

trigger_argocd_sync() {
    local apps=("argocd" "gitea" "keycloak" "minio")
    
    log_info "Triggering one-time ArgoCD sync for critical applications..."
    
    for app in "${apps[@]}"; do
        log_info "Syncing application: $app"
        if kubectl patch application "$app" -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"simplified-domain-change"},"sync":{"syncStrategy":{"apply":{"force":true}}}}}' 2>/dev/null; then
            log_success "Triggered sync for $app"
        else
            log_warning "Could not trigger sync for $app (may not exist)"
        fi
    done
    
    log_info "Waiting 30 seconds for sync propagation..."
    sleep 30
}

verify_domain() {
    local new_domain=$1
    
    log_info "Verifying new domain accessibility..."
    
    local retries=3
    local delay=15
    
    for ((i=1; i<=retries; i++)); do
        if curl -k -s --max-time 10 "https://argocd.$new_domain/api/version" &>/dev/null; then
            log_success "New domain is accessible!"
            return 0
        else
            log_warning "Attempt $i/$retries: Domain not yet accessible, waiting ${delay}s..."
            sleep $delay
        fi
    done
    
    log_warning "Domain verification failed - may need more time to propagate"
    return 1
}

main() {
    # Check arguments
    if [[ $# -lt 3 ]] || [[ $# -gt 4 ]]; then
        show_usage
    fi
    
    local new_domain=$1
    local cert_path=$2
    local key_path=$3
    local old_domain=${4:-""}
    
    # Determine old domain if not provided
    if [[ -z "$old_domain" ]]; then
        log_info "OLD_DOMAIN not provided, attempting to extract from cluster configuration..."
        old_domain=$(get_current_domain)
        if [[ "$old_domain" == "unknown" ]]; then
            log_error "Could not determine old domain automatically. Please provide it as the 4th argument."
        fi
        log_success "Extracted old domain: $old_domain"
    fi
    
    # Construct cluster-values repository URL
    local cluster_values_repo_url="https://gitea.$old_domain/infrastructure/cluster-values.git"
    
    echo "🚀 Simplified Domain Change Script"
    echo "================================="
    echo "Old domain: $old_domain"
    echo "New domain: $new_domain"
    echo "Certificate: $cert_path"
    echo "Private key: $key_path"
    echo "Repository: $cluster_values_repo_url"
    echo ""
    
    # Validation
    log_info "Validating prerequisites..."
    validate_domain "$new_domain"
    validate_files "$cert_path" "$key_path"
    check_kubectl
    
    # Detect cluster-bloom DNS configuration
    detect_cluster_bloom_dns
    
    # Confirmation
    echo ""
    read -p "Continue with domain change? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Domain change cancelled"
        exit 0
    fi
    
    # Execute domain change steps
    echo ""
    log_info "Starting domain change process..."
    
    update_cluster_values_repo "$new_domain" "$cluster_values_repo_url"
    update_dnsmasq_config "$new_domain"
    apply_tls_certificates "$new_domain" "$cert_path" "$key_path"
    update_domain_configmap "$new_domain"
    trigger_argocd_sync
    
    # Verification
    echo ""
    if verify_domain "$new_domain"; then
        domain_status="✅ New domain is accessible"
    else
        domain_status="⚠️ Domain check failed - may need time to propagate"
    fi
    
    # Success summary
    echo ""
    echo "🎯 Domain Change Complete with DNS Integration!"
    echo "==============================================="
    echo "✅ Updated cluster-values repository with new domain"
    if [[ "$CLUSTER_BLOOM_DNS_ENABLED" == "true" ]]; then
        echo "✅ Updated system DNS (DNSMASQ) configuration"
    else
        echo "⚠️  No system DNS (DNSMASQ) detected - cluster-bloom not used"
    fi
    echo "✅ Applied new TLS certificates to cluster"
    echo "✅ Updated domain ConfigMap (no automatic watching)"
    echo "✅ Triggered one-time ArgoCD sync"
    echo "$domain_status"
    echo ""
    echo "Domain Integration Summary:"
    echo "• Previous domain: ${old_domain} (K8s) / ${CURRENT_DNS_DOMAIN:-none} (DNS)"
    echo "• New domain: $new_domain"
    echo "• Cluster-Bloom DNS: $([ "$CLUSTER_BLOOM_DNS_ENABLED" == "true" ] && echo "ENABLED and UPDATED" || echo "NOT DETECTED")"
    echo "• FIX_DNS was used: $([ "$CLUSTER_BLOOM_FIX_DNS_USED" == "true" ] && echo "YES" || echo "NO")"
    echo ""
    echo "Access URLs:"
    echo "• ArgoCD:   https://argocd.$new_domain"
    echo "• Gitea:    https://gitea.$new_domain"
    echo "• Keycloak: https://kc.$new_domain"
    echo ""
    echo "${FIRE} The fire of the forge eliminates impurities!"
    echo ""
    echo "Note: This simplified implementation removes all automatic"
    echo "watching/polling. Future domain changes require re-running"
    echo "this script manually."
}

# Execute main function
main "$@"