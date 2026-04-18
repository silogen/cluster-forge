#!/bin/bash
# ClusterForge Ansible Bootstrap - Standalone Installer
# This script can be downloaded and run directly to bootstrap a cluster
# without needing to clone the full repository first.
#
# Usage:
#   curl -sfL https://raw.githubusercontent.com/yourorg/cluster-forge/main/ansible/install.sh | bash -s -- example.com
#
# Or download and run locally:
#   wget https://raw.githubusercontent.com/yourorg/cluster-forge/main/ansible/install.sh
#   chmod +x install.sh
#   ./install.sh example.com --cluster-size medium

set -euo pipefail

# Configuration
REPO_URL="${CLUSTER_FORGE_REPO:-https://github.com/yourorg/cluster-forge.git}"
BRANCH="${CLUSTER_FORGE_BRANCH:-main}"
INSTALL_DIR="${HOME}/.cluster-forge-ansible"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_dependencies() {
    local missing_deps=()
    
    log_info "Checking dependencies..."
    
    for cmd in git ansible kubectl helm yq openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install the missing dependencies:"
        echo ""
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                ansible)
                    echo "  Ansible: https://docs.ansible.com/ansible/latest/installation_guide/"
                    echo "    Ubuntu/Debian: sudo apt install ansible"
                    echo "    macOS: brew install ansible"
                    ;;
                kubectl)
                    echo "  kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
                    ;;
                helm)
                    echo "  Helm: https://helm.sh/docs/intro/install/"
                    ;;
                yq)
                    echo "  yq: https://github.com/mikefarah/yq#install"
                    ;;
                git)
                    echo "  git: Usually pre-installed or via package manager"
                    ;;
                openssl)
                    echo "  openssl: Usually pre-installed"
                    ;;
            esac
            echo ""
        done
        exit 1
    fi
    
    log_info "✅ All dependencies found"
}

clone_ansible_directory() {
    log_info "Cloning ClusterForge Ansible bootstrap..."
    
    # Clean up existing directory
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "Removing existing installation at $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    # Clone only the ansible directory using sparse checkout
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    git init
    git remote add origin "$REPO_URL"
    git config core.sparseCheckout true
    echo "ansible/*" > .git/info/sparse-checkout
    
    log_info "Fetching ansible directory from branch: $BRANCH"
    git fetch --depth 1 origin "$BRANCH"
    git checkout "$BRANCH"
    
    cd ansible
    log_info "✅ Ansible bootstrap files ready at: $INSTALL_DIR/ansible"
}

install_collections() {
    log_info "Installing Ansible collections..."
    cd "$INSTALL_DIR/ansible"
    
    if [ -f requirements.yml ]; then
        ansible-galaxy collection install -r requirements.yml
        log_info "✅ Ansible collections installed"
    else
        log_warn "requirements.yml not found, skipping collection installation"
    fi
}

show_usage() {
    cat <<EOF
ClusterForge Standalone Installer

This script sets up the Ansible bootstrap environment and can optionally run the bootstrap.

Usage: $0 [domain] [options]

If domain is provided, bootstrap will run automatically.
If domain is not provided, only the setup will be performed.

Options:
  --cluster-size <size>       Cluster size: small, medium, or large (default: medium)
  --target-revision <rev>     Git revision to bootstrap from (default: v2.0.4)
  --repo <url>                ClusterForge repository URL
  --branch <branch>           Branch to use for Ansible files (default: main)
  --aiwb-only                 Deploy only AIWB components
  --disabled-apps <apps>      Disable specific apps (comma-separated)
  --setup-only                Only setup Ansible, don't run bootstrap
  --help                      Show this message

Examples:
  $0 example.com
  $0 example.com --cluster-size large
  $0 --setup-only
  $0 example.com --aiwb-only --cluster-size medium

After setup, you can also run bootstrap manually:
  cd ~/.cluster-forge-ansible/ansible
  ./run-bootstrap.sh your-domain.com

EOF
}

# Parse arguments
DOMAIN=""
BOOTSTRAP_ARGS=""
SETUP_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            show_usage
            exit 0
            ;;
        --setup-only)
            SETUP_ONLY=true
            shift
            ;;
        --repo)
            REPO_URL="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --cluster-size|--target-revision|--disabled-apps)
            BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS $1 $2"
            shift 2
            ;;
        --aiwb-only)
            BOOTSTRAP_ARGS="$BOOTSTRAP_ARGS $1"
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            else
                log_error "Unexpected argument: $1"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Main execution
main() {
    echo "╔════════════════════════════════════════════════════╗"
    echo "║   ClusterForge Ansible Bootstrap Installer         ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    
    check_dependencies
    clone_ansible_directory
    install_collections
    
    echo ""
    log_info "✅ Setup complete!"
    echo ""
    
    if [ "$SETUP_ONLY" = true ]; then
        log_info "Setup-only mode. To run bootstrap:"
        echo "  cd $INSTALL_DIR/ansible"
        echo "  ./run-bootstrap.sh your-domain.com"
        echo ""
        echo "Or use the Makefile:"
        echo "  cd $INSTALL_DIR/ansible"
        echo "  make bootstrap DOMAIN=your-domain.com"
        exit 0
    fi
    
    if [ -z "$DOMAIN" ]; then
        log_warn "No domain provided. Setup complete but bootstrap not run."
        echo ""
        echo "To run bootstrap now:"
        echo "  cd $INSTALL_DIR/ansible"
        echo "  ./run-bootstrap.sh your-domain.com"
        echo ""
        echo "Or run this installer again with a domain:"
        echo "  $0 your-domain.com"
        exit 0
    fi
    
    # Run bootstrap
    log_info "Running bootstrap for domain: $DOMAIN"
    echo ""
    
    cd "$INSTALL_DIR/ansible"
    
    # shellcheck disable=SC2086
    ./run-bootstrap.sh "$DOMAIN" $BOOTSTRAP_ARGS
    
    echo ""
    log_info "✅ Bootstrap complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Access ArgoCD: https://argocd.$DOMAIN"
    echo "  2. Access Gitea: https://gitea.$DOMAIN"
    echo "  3. Monitor applications: kubectl get applications -n argocd"
    echo ""
    echo "Ansible files are available at: $INSTALL_DIR/ansible"
}

main "$@"
