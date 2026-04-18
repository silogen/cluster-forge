#!/bin/bash
# Helper script to run ClusterForge Ansible bootstrap
# This provides a simpler interface similar to bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/bootstrap.yml"
VARS_FILE=""
EXTRA_ARGS=""

show_help() {
    cat <<EOF
ClusterForge Ansible Bootstrap Helper

Usage: $0 [options] <domain>

Arguments:
  domain                        REQUIRED. Cluster domain (e.g., example.com, 192.168.1.100.nip.io)

Options:
  -s, --cluster-size <size>    Cluster size: small, medium (default), or large
  -r, --target-revision <rev>  Git revision to use (default: v2.0.4)
  -f, --vars-file <file>       Use variables from file (e.g., vars/my-cluster.yml)
  --repo <url>                 ClusterForge repository URL
  --apps <apps>                Deploy only specific apps (comma-separated)
  --disabled-apps <apps>       Disable specific apps (comma-separated, supports wildcards)
  --aiwb-only                  Deploy only AIWB components
  --template-only              Generate YAML without applying to cluster
  --skip-deps                  Skip dependency checking
  --cleanup                    Remove cloned repository after bootstrap
  -v, --verbose                Enable verbose output
  -h, --help                   Show this help message

Examples:
  $0 example.com
  $0 example.com --cluster-size small
  $0 example.com --vars-file vars/production.yml
  $0 192.168.1.100.nip.io --cluster-size medium --target-revision v2.0.3
  $0 example.com --disabled-apps airm,airm-infra-*
  $0 example.com --aiwb-only
  $0 example.com --apps openbao

Environment Variables:
  CLUSTER_FORGE_REPO           Default repository URL (can be set in ~/.bashrc)

EOF
}

# Parse arguments
DOMAIN=""
ANSIBLE_EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--cluster-size)
            EXTRA_ARGS="${EXTRA_ARGS} -e cluster_size=$2"
            shift 2
            ;;
        -r|--target-revision)
            EXTRA_ARGS="${EXTRA_ARGS} -e cluster_forge_target_revision=$2"
            shift 2
            ;;
        -f|--vars-file)
            VARS_FILE="$2"
            shift 2
            ;;
        --repo)
            EXTRA_ARGS="${EXTRA_ARGS} -e cluster_forge_repo=$2"
            shift 2
            ;;
        --apps)
            EXTRA_ARGS="${EXTRA_ARGS} -e apps=$2"
            shift 2
            ;;
        --disabled-apps)
            EXTRA_ARGS="${EXTRA_ARGS} -e disabled_apps=$2"
            shift 2
            ;;
        --aiwb-only)
            EXTRA_ARGS="${EXTRA_ARGS} -e aiwb_only=true"
            shift
            ;;
        --template-only)
            EXTRA_ARGS="${EXTRA_ARGS} -e template_only=true"
            shift
            ;;
        --skip-deps)
            EXTRA_ARGS="${EXTRA_ARGS} -e skip_dependency_check=true"
            shift
            ;;
        --cleanup)
            EXTRA_ARGS="${EXTRA_ARGS} -e cleanup_clone=true"
            shift
            ;;
        -v|--verbose)
            ANSIBLE_EXTRA_ARGS="${ANSIBLE_EXTRA_ARGS} -vvv"
            shift
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            else
                echo "ERROR: Too many arguments: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate domain
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain is required"
    echo "Use --help for usage information"
    exit 1
fi

# Add domain to extra args
EXTRA_ARGS="${EXTRA_ARGS} -e cluster_domain=${DOMAIN}"

# Use environment variable for repo if set and not overridden
if [ -n "${CLUSTER_FORGE_REPO:-}" ] && [[ ! "$EXTRA_ARGS" =~ cluster_forge_repo ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} -e cluster_forge_repo=${CLUSTER_FORGE_REPO}"
fi

# Build ansible-playbook command
CMD="ansible-playbook ${PLAYBOOK}"

if [ -n "$VARS_FILE" ]; then
    CMD="${CMD} -e @${VARS_FILE}"
fi

CMD="${CMD} ${EXTRA_ARGS} ${ANSIBLE_EXTRA_ARGS}"

# Display command being run
echo "Running: $CMD"
echo ""

# Execute
eval $CMD
