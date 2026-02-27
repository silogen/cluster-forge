#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize variables
LATEST_RELEASE="v1.8.0"
TARGET_REVISION="$LATEST_RELEASE"

CLUSTER_SIZE="medium"  # Default to medium
DOMAIN=""
KUBE_VERSION=1.33
VALUES_FILE="values.yaml"

# Parse arguments 
while [[ $# -gt 0 ]]; do
  case $1 in
    --CLUSTER-SIZE|--cluster-size|-s)
        if [ -z "$2" ]; then
          echo "ERROR: --cluster-size requires an argument"
          exit 1
        fi
        CLUSTER_SIZE="$2"
        shift 2
        ;;
      --CLUSTER-SIZE=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      --cluster-size=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      -s=*)
        CLUSTER_SIZE="${1#*=}"
        shift
        ;;
      --TARGET-REVISION|--target-revision|-r)
        if [ -z "$2" ]; then
          echo "WARNING: defaulting to --target-revision=$LATEST_RELEASE (no value specified)"
          TARGET_REVISION="$LATEST_RELEASE"
          shift
        else
          TARGET_REVISION="$2"
          shift 2
        fi
        ;;
      --TARGET-REVISION=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
      --target-revision=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
      -r=*)
        TARGET_REVISION="${1#*=}"
        shift
        ;;
    --help|-h)
      cat <<HELP_OUTPUT
      Usage: $0 [options] <domain> [values_file]

      Arguments:
        domain                      Required. Cluster domain (e.g., example.com)
        values_file                 Optional. Values .yaml file to use, default: root/values.yaml
      
      Options:
        -r, --target-revision       cluster-forge git revision to seed into cluster-values/values.yaml file 
                                    options: [tag|commit_hash|branch_name], default: $LATEST_RELEASE
        -s, --cluster-size          options: [small|medium|large], default: medium

      Examples:
        $0 compute.amd.com values_custom.yaml --cluster-size=large
        $0 112.100.97.17.nip.io
        $0 dev.example.com --cluster-size=small --target-revision=$LATEST_RELEASE
        $0 dev.example.com -s=small -r=$LATEST_RELEASE
HELP_OUTPUT
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      # Positional arguments
      if [ -z "$DOMAIN" ]; then
        DOMAIN="$1"
      elif [ "$VALUES_FILE" = "values.yaml" ]; then
        VALUES_FILE="$1"
      else
        echo "ERROR: Too many arguments: $1"
        echo "Usage: $0 [--CLUSTER_SIZE=small|medium|large] [--dev] <domain> [values_file]"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate required arguments
if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain argument is required"
    echo "Usage: $0 <domain> [values_file] [--CLUSTER_SIZE=small|medium|large]"
    echo "Use --help for more details"
    exit 1
fi

# Validate cluster size
case "$CLUSTER_SIZE" in
  small|medium|large)
    ;;
  *)
    echo "ERROR: Invalid cluster size '$CLUSTER_SIZE'"
    echo "Valid sizes: small, medium, large"
    exit 1
    ;;
esac

# Validate values file exists
if [ ! -f "${SCRIPT_DIR}/../root/${VALUES_FILE}" ]; then
    echo "ERROR: Values file not found: ${SCRIPT_DIR}/../root/${VALUES_FILE}"
    exit 1
fi

# Check if size-specific values file exists
setup_values_files() {
    SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
    
    if [ ! -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
        echo "WARNING: Size-specific values file not found: ${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}"
        echo "Proceeding with base values file only: ${VALUES_FILE}"
        SIZE_VALUES_FILE=""
    else
        echo "Using size-specific values file: ${SIZE_VALUES_FILE}"
    fi
}

display_target_revision() {
  # Check if TARGET_REVISION was explicitly set via command line flag
  # by comparing against the default value
  if [ "$TARGET_REVISION" != "$LATEST_RELEASE" ]; then 
    echo "Using specified targetRevision: $TARGET_REVISION"
  else
    echo "Using default targetRevision: $TARGET_REVISION"
  fi
}

# Since we only support v1.8.0+, always use local sources
setup_sources() {
    SOURCE_ROOT="${SCRIPT_DIR}/.."
    echo "Using local sources for target revision: $TARGET_REVISION"
}

pre_cleanup() {
    echo ""
    echo "=== Pre-cleanup: Checking for previous runs ==="

    # Check if gitea-init-job exists and completed successfully
    if kubectl get job gitea-init-job -n cf-gitea >/dev/null 2>&1; then
        if kubectl get job gitea-init-job -n cf-gitea -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q "True"; then
            echo "Found completed gitea-init-job - removing Gitea to start fresh"

            # Delete all Gitea resources
            kubectl delete job gitea-init-job -n cf-gitea --ignore-not-found=true
            kubectl delete deployment gitea -n cf-gitea --ignore-not-found=true
            kubectl delete statefulset gitea -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea-http -n cf-gitea --ignore-not-found=true
            kubectl delete service gitea-ssh -n cf-gitea --ignore-not-found=true
            kubectl delete pvc -n cf-gitea -l app.kubernetes.io/name=gitea --ignore-not-found=true
            kubectl delete configmap initial-cf-values -n cf-gitea --ignore-not-found=true
            kubectl delete secret gitea-admin-credentials -n cf-gitea --ignore-not-found=true
            kubectl delete ingress -n cf-gitea -l app.kubernetes.io/name=gitea --ignore-not-found=true

            echo "Gitea resources deleted"
        fi
    fi

    # Always delete openbao-init-job to allow re-initialization
    kubectl delete job openbao-init-job -n cf-openbao --ignore-not-found=true

    # Clean up any bootstrap manifest files from previous runs
    rm -f /tmp/cluster-forge-bootstrap.yaml

    echo "=== Pre-cleanup complete ==="
    echo ""
}

# NEW: ArgoCD-Native Template Rendering Function
render_cluster_forge_manifests() {
    echo ""
    echo "=== Rendering ClusterForge Manifests ==="
    echo "Domain: $DOMAIN"
    echo "Base values: $VALUES_FILE"
    echo "Cluster size: $CLUSTER_SIZE"
    echo "Target revision: $TARGET_REVISION"
    echo ""

    local helm_args=(
        "cluster-forge" "${SOURCE_ROOT}/root"
        "--namespace" "argocd"
        "--values" "${SOURCE_ROOT}/root/${VALUES_FILE}"
    )

    # Add size-specific values if they exist
    if [ -n "$SIZE_VALUES_FILE" ]; then
        helm_args+=(
            "--values" "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}"
        )
        echo "Size overlay: $SIZE_VALUES_FILE"
    fi

    # Set runtime configuration
    helm_args+=(
        "--set" "global.domain=$DOMAIN"
        "--set" "global.clusterSize=values_${CLUSTER_SIZE}.yaml"
        "--set" "externalValues.enabled=true"
        "--set" "clusterForge.repoUrl=http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git"
        "--set" "clusterForge.targetRevision=$TARGET_REVISION"
        "--set" "externalValues.repoUrl=http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git"
        "--set" "externalValues.targetRevision=main"
        "--kube-version" "$KUBE_VERSION"
    )

    echo "🚀 Rendering all manifests using ArgoCD-native templating..."
    
    # Render all manifests in one go - no yq, no temp files, no manual extraction!
    helm template "${helm_args[@]}" > /tmp/cluster-forge-bootstrap.yaml

    echo "✅ All manifests rendered to /tmp/cluster-forge-bootstrap.yaml"
    echo ""
}

# NEW: Smart Application of Sync Waves
apply_manifests_by_sync_wave() {
    echo "=== Applying Manifests by Sync Wave ==="

    # Create required namespaces first
    echo "Creating namespaces..."
    kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
    kubectl create ns cf-openbao --dry-run=client -o yaml | kubectl apply -f -

    # Apply manifests - ArgoCD will handle sync waves naturally
    echo "🎯 Applying all ClusterForge manifests..."
    kubectl apply -f /tmp/cluster-forge-bootstrap.yaml

    echo ""
    echo "🎉 Bootstrap manifests applied!"
    echo "ArgoCD will now orchestrate the deployment using sync waves."
    echo ""
    echo "=== Monitoring Key Components ==="
    
    # Wait for ArgoCD to be ready (it should be in the bootstrap manifests)
    if kubectl get statefulset argocd-application-controller -n argocd >/dev/null 2>&1; then
        echo "⏳ Waiting for ArgoCD Application Controller..."
        kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
        echo "✅ ArgoCD Application Controller ready"
    fi

    if kubectl get deployment argocd-repo-server -n argocd >/dev/null 2>&1; then
        echo "⏳ Waiting for ArgoCD Repo Server..."
        kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
        echo "✅ ArgoCD Repo Server ready"
    fi

    # Monitor progress of core applications
    echo ""
    echo "📊 Core applications will be deployed by ArgoCD in sync wave order:"
    echo "   Wave -5: CRDs and operators"
    echo "   Wave -4: Core infrastructure (ArgoCD, OpenBao, External Secrets)"
    echo "   Wave -3: Network and storage"
    echo "   Wave -2: Configuration and secrets management"
    echo "   Wave -1: Application dependencies" 
    echo "   Wave  0: Applications"
    echo ""
}

# NEW: Post-Bootstrap Status Check
show_bootstrap_summary() {
    echo "=== ClusterForge Bootstrap Complete ==="
    echo ""
    echo "Domain: $DOMAIN"
    echo "Cluster size: $CLUSTER_SIZE"
    echo "Target revision: $TARGET_REVISION"
    echo ""
    echo "🌐 Access URLs:"
    echo "  ArgoCD:  https://argocd.${DOMAIN}"
    echo "  Gitea:   https://gitea.${DOMAIN}"
    echo ""
    echo "📋 Next steps:"
    echo "  1. Monitor ArgoCD applications: kubectl get apps -n argocd"
    echo "  2. Check sync status: kubectl get apps -n argocd -o wide"
    echo "  3. View ArgoCD UI for detailed deployment progress"
    echo ""
    echo "🧹 Cleanup: Bootstrap manifest saved at /tmp/cluster-forge-bootstrap.yaml"
    echo ""
    echo "This is the way! 🚀"
}

# Main execution flow
main() {
    display_target_revision
    setup_sources
    setup_values_files
    
    # Run pre-cleanup (removing till refined)
    # pre_cleanup
    
    # NEW APPROACH: Single ArgoCD-native rendering and application
    render_cluster_forge_manifests
    apply_manifests_by_sync_wave
    
    # Show final status
    show_bootstrap_summary
}

# Execute main function
main