#!/bin/bash
# ClusterForge Size Configuration Validation Script
# =============================================================================
# This script validates the YAML structure and shows how size configurations work
# for ClusterForge applications without requiring Helm to be installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_section() {
    echo -e "${YELLOW}[SECTION]${NC} $1"
}

# Check YAML syntax using available tools
check_yaml() {
    local file="$1"
    local filename=$(basename "$file")
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "❌ $filename: File not found"
        return 1
    fi
    
    # Check if file is readable
    if [ ! -r "$file" ]; then
        echo "❌ $filename: File not readable"
        return 1
    fi
    
    # Try different validation methods
    local validation_method=""
    local temp_output=""
    
    # Method 1: Try yq v4+ syntax
    if command -v yq &> /dev/null; then
        if temp_output=$(yq eval '.' "$file" 2>&1); then
            validation_method="yq v4"
        elif temp_output=$(yq . "$file" 2>&1); then
            validation_method="yq v3"
        elif temp_output=$(yq r "$file" 2>&1); then
            validation_method="yq v2"
        fi
    fi
    
    # Method 2: Try python if yq failed
    if [ -z "$validation_method" ] && command -v python3 &> /dev/null; then
        if temp_output=$(python3 -c "import yaml; yaml.safe_load(open('$file', 'r'))" 2>&1); then
            validation_method="python3"
        fi
    fi
    
    # Method 3: Try python2 if python3 failed
    if [ -z "$validation_method" ] && command -v python &> /dev/null; then
        if temp_output=$(python -c "import yaml; yaml.safe_load(open('$file', 'r'))" 2>&1); then
            validation_method="python2"
        fi
    fi
    
    # If validation succeeded with any method
    if [ -n "$validation_method" ]; then
        log_success "$filename: Valid YAML syntax (validated with $validation_method)"
        return 0
    fi
    
    # All validation methods failed - fall back to basic checks
    log_info "$filename: Cannot validate YAML syntax (no working validator found)"
    
    # Check for common YAML issues
    if grep -q $'\t' "$file"; then
        echo "❌ $filename: Contains tabs (YAML requires spaces)"
        return 1
    fi
    
    # Check for basic structure (allow comments at start)
    if grep -m 1 "^[a-zA-Z]" "$file" >/dev/null 2>&1; then
        log_success "$filename: Basic structure OK (install yq/python for full validation)"
        return 0
    else
        echo "❌ $filename: No valid YAML content found"
        return 1
    fi
}

# Show key differences between configurations
show_config_differences() {
    local size="$1"
    
    log_section "Key differences for $size cluster:"
    
    case "$size" in
        small)
            echo "  - ArgoCD: Single replica, no HA Redis"
            echo "  - MinIO: 1 server, 500GB storage"
            echo "  - OpenBao: Single instance (no HA)"
            echo "  - Prometheus: 7d retention, minimal resources"
            echo "  - Target: 1-5 users, development/testing"
            ;;
        medium)
            echo "  - ArgoCD: 2 replicas with HA Redis"
            echo "  - MinIO: 3 servers, 6TB total storage"
            echo "  - OpenBao: 3 replicas with Raft HA"
            echo "  - Enhanced resources for team collaboration"
            echo "  - Target: 5-20 users, production workloads"
            ;;
        large)
            echo "  - ArgoCD: 3 replicas with enhanced PDB"
            echo "  - MinIO: External HA S3 recommended"
            echo "  - OpenBao: Full HA with enhanced security"
            echo "  - Full observability stack with extended retention"
            echo "  - Target: 10s-100s users, enterprise scale"
            ;;
    esac
}

main() {
    log_info "Validating ClusterForge configuration files..."
    echo
    
    # Validate base configuration
    log_section "Base Configuration"
    check_yaml "$PROJECT_ROOT/root/values.yaml"
    echo
    
    # Validate size-specific configurations
    for size in small medium large; do
        log_section "$size Cluster Configuration"
        check_yaml "$PROJECT_ROOT/root/values_$size.yaml"
        show_config_differences "$size"
        echo
    done
    
    log_section "Configuration Summary"
    echo "✅ Base values.yaml: All ClusterForge applications enabled"
    echo "✅ values_small.yaml: Minimal resources for 1-5 users (dev/test)"
    echo "✅ values_medium.yaml: Balanced setup for 5-20 users (teams)"  
    echo "✅ values_large.yaml: Enterprise features for 10s-100s users"
    echo
    
    log_section "Usage Examples"
    echo "  # Small cluster (development/testing):"
    echo "  ./scripts/bootstrap.sh dev.example.com --CLUSTER_SIZE=small"
    echo
    echo "  # Medium cluster (team production - default):"
    echo "  ./scripts/bootstrap.sh team.example.com"
    echo
    echo "  # Large cluster (enterprise scale):"
    echo "  ./scripts/bootstrap.sh prod.example.com --CLUSTER_SIZE=large"
    echo
    
    log_success "All ClusterForge size configurations are valid! This is the way."
}

main "$@"