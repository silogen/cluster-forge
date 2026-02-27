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
        -r, --target-revision       cluster-forge git revision for ArgoCD to sync from 
                                    options: [tag|commit_hash|branch_name], default: $LATEST_RELEASE
                                    IMPORTANT: Only apps enabled in target revision will be deployed
        -s, --cluster-size          options: [small|medium|large], default: medium

      Examples:
        $0 compute.amd.com values_custom.yaml --cluster-size=large
        $0 112.100.97.17.nip.io
        $0 dev.example.com --cluster-size=small --target-revision=v1.8.0
        $0 dev.example.com -s=small -r=feature-branch
        
      Target Revision Behavior:
        • Bootstrap will deploy ArgoCD + essential infrastructure (Gitea, OpenBao)
        • Gitea will be initialized to provide git repositories for ArgoCD
        • OpenBao will be initialized to provide secrets management
        • cluster-forge parent app will then be deployed to manage remaining apps
        • ArgoCD will sync ALL apps from the specified target revision
        • Only apps enabled in target revision will be deployed
        • Apps disabled in target revision will be pruned if they exist
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
    rm -f /tmp/cluster-forge-bootstrap.yaml /tmp/cluster-forge-parent-app.yaml \
          /tmp/argocd-app.yaml /tmp/gitea-app.yaml /tmp/openbao-app.yaml

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

# NEW: Render and Apply Only Essential Components for ArgoCD Takeover  
render_cluster_forge_parent_app() {
    echo ""
    echo "=== Rendering cluster-forge Parent App ==="
    echo "Using existing template: root/templates/cluster-forge.yaml"
    echo "Target revision: $TARGET_REVISION"
    echo "Cluster size: $CLUSTER_SIZE"

    # Create minimal values for just rendering the cluster-forge parent app
    local temp_values=$(mktemp)
    cat > "$temp_values" <<EOF
# Minimal values for cluster-forge parent app rendering
externalValues:
  enabled: true
  path: ${VALUES_FILE}
  repoUrl: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git
  targetRevision: main

clusterForge:
  repoUrl: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-forge.git
  targetRevision: ${TARGET_REVISION}
  valuesFile: ${VALUES_FILE}

global:
  domain: ${DOMAIN}
  clusterSize: values_${CLUSTER_SIZE}.yaml
EOF

    echo "🎯 Rendering cluster-forge parent app using template..."
    
    # Render only the cluster-forge template
    helm template cluster-forge "${SOURCE_ROOT}/root" \
        --show-only templates/cluster-forge.yaml \
        --values "$temp_values" \
        --namespace argocd \
        --kube-version "$KUBE_VERSION" > /tmp/cluster-forge-parent-app.yaml

    # Cleanup temp file
    rm -f "$temp_values"
    
    echo "✅ cluster-forge parent app rendered to /tmp/cluster-forge-parent-app.yaml"
}

bootstrap_argocd_managed_approach() {
    echo "=== ArgoCD-Managed Bootstrap ==="
    echo ""
    echo "🎯 Strategy: Let ArgoCD manage everything from target revision: $TARGET_REVISION"
    echo "   This ensures only apps enabled in target revision are deployed"
    echo "   Note: Using yq for reliable ArgoCD application extraction only"
    echo ""

    # Create argocd namespace first
    echo "Creating ArgoCD namespace..."
    kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -

    # Step 1: Deploy ArgoCD itself from local render (needed to bootstrap)
    echo ""
    echo "📦 Step 1: Deploying ArgoCD..."
    
    # Use yq to reliably extract the ArgoCD application (acceptable for ArgoCD setup)
    echo "Extracting ArgoCD application using yq (for bootstrap reliability only)..."
    
    # Check if yq command is available
    if command -v yq >/dev/null 2>&1; then
        YQ_CMD="yq"
    elif [ -f "$HOME/yq" ]; then
        YQ_CMD="$HOME/yq"
    else
        echo "ERROR: yq command not found. Please install yq or place it in $HOME/yq"
        exit 1
    fi
    
    # Extract ArgoCD application using yq
    $YQ_CMD eval 'select(.kind == "Application" and .metadata.name == "argocd")' /tmp/cluster-forge-bootstrap.yaml > /tmp/argocd-app.yaml
    
    # Verify we got a valid ArgoCD application
    if [ -s /tmp/argocd-app.yaml ] && grep -q "kind: Application" /tmp/argocd-app.yaml; then
        echo "✅ Extracted ArgoCD application using yq"
        kubectl apply -f /tmp/argocd-app.yaml
    else
        echo "ERROR: Could not extract ArgoCD application from rendered manifests"
        echo "Available applications:"
        $YQ_CMD eval '.metadata.name' /tmp/cluster-forge-bootstrap.yaml | grep -v "null" | head -10
        exit 1
    fi
    
    rm -f /tmp/argocd-app.yaml

    # Wait for ArgoCD to be ready
    echo "⏳ Waiting for ArgoCD to become ready..."
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=300s
    kubectl rollout status deploy/argocd-redis -n argocd --timeout=300s
    echo "✅ ArgoCD ready!"

    # Step 2: Deploy Gitea directly (cannot be deployed by ArgoCD initially)
    echo ""
    echo "📦 Step 2: Deploying Gitea directly..."
    echo "   Note: Gitea must be deployed directly to provide git repositories for ArgoCD"
    
    deploy_gitea_directly
    
    # Step 3: Deploy OpenBao via ArgoCD (it can be managed by ArgoCD)
    echo ""
    echo "📦 Step 3: Deploying OpenBao via ArgoCD..."
    echo "   Extracting and deploying OpenBao..."
    $YQ_CMD eval 'select(.kind == "Application" and .metadata.name == "openbao")' /tmp/cluster-forge-bootstrap.yaml > /tmp/openbao-app.yaml
    kubectl apply -f /tmp/openbao-app.yaml
    echo "✅ OpenBao application deployed"

    # Step 4: Initialize infrastructure
    echo ""
    echo "📦 Step 4: Initializing essential infrastructure..."

    echo ""
    echo "🎉 ArgoCD-Managed Bootstrap Complete!"
    echo ""
    echo "📋 What happens now:"
    echo "   1. ✅ ArgoCD is running and managing the cluster"
    echo "   2. 🎯 cluster-forge app will sync from: $TARGET_REVISION"
    echo "   3. 📦 ONLY apps enabled in $TARGET_REVISION will be deployed"
    echo "   4. ⚡ Sync waves will ensure proper deployment order"
    echo "   5. 🔄 ArgoCD will automatically prune apps disabled in target revision"
    # Wait for Gitea to be deployed and initialize (critical for git repositories)
    wait_for_gitea_and_initialize
    
    # Wait for OpenBao to be deployed and initialize (critical for secrets) 
    wait_for_openbao_and_initialize

    # Step 4: Now apply the cluster-forge parent app (after git repositories exist)
    echo ""
    echo "📦 Step 4: Applying cluster-forge parent application..."
    echo "   Now that git repositories exist, ArgoCD can manage all remaining apps"

    # Render the cluster-forge parent app using the existing template
    render_cluster_forge_parent_app

    # Apply the rendered cluster-forge parent app
    kubectl apply -f /tmp/cluster-forge-parent-app.yaml

    echo "✅ cluster-forge parent application applied!"
    echo "🚀 ArgoCD will now manage all remaining applications from target revision: $TARGET_REVISION"
}

# Deploy Gitea directly using helm (cannot rely on ArgoCD initially)
deploy_gitea_directly() {
    echo ""
    echo "=== Direct Gitea Deployment ==="
    echo "Gitea must be deployed directly since ArgoCD needs git repositories to function"
    
    # Create cf-gitea namespace first
    echo "Creating cf-gitea namespace..."
    kubectl create ns cf-gitea --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if yq is available for value extraction
    if command -v yq >/dev/null 2>&1; then
        YQ_CMD="yq"
    elif [ -f "$HOME/yq" ]; then
        YQ_CMD="$HOME/yq"
    else
        echo "ERROR: yq command not found. Please install yq or place it in $HOME/yq"
        exit 1
    fi
    
    # Extract Gitea version from values
    echo "Extracting Gitea configuration..."
    
    # Create merged values for version extraction (similar to original bootstrap.sh)
    local SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
    if [ -n "$SIZE_VALUES_FILE" ] && [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
        # Merge base values with size-specific overrides  
        $YQ_CMD eval-all '. as $item ireduce ({}; . * $item)' \
            "${SOURCE_ROOT}/root/${VALUES_FILE}" \
            "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | \
            $YQ_CMD eval ".global.domain = \"${DOMAIN}\"" > /tmp/merged_values.yaml
    else
        # Use base values only
        cat "${SOURCE_ROOT}/root/${VALUES_FILE}" | $YQ_CMD ".global.domain = \"${DOMAIN}\"" > /tmp/merged_values.yaml
    fi
    
    # Extract Gitea version from merged values
    GITEA_VERSION=$($YQ_CMD eval '.apps.gitea.path' /tmp/merged_values.yaml | cut -d'/' -f2)
    
    if [ -z "$GITEA_VERSION" ]; then
        echo "ERROR: Could not extract Gitea version from values"
        exit 1
    fi
    
    echo "Using Gitea version: $GITEA_VERSION"
    
    # Extract Gitea-specific values for helm template
    $YQ_CMD eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > /tmp/gitea_values.yaml
    
    if [ -f "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" ]; then
        $YQ_CMD eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/gitea_size_values.yaml
    else
        # Create empty file if size-specific values don't exist
        echo "{}" > /tmp/gitea_size_values.yaml
    fi
    
    # Deploy Gitea directly using helm template
    echo "🚀 Deploying Gitea using helm template..."
    helm template --release-name gitea "${SOURCE_ROOT}/sources/gitea/${GITEA_VERSION}" --namespace cf-gitea \
        -f /tmp/gitea_values.yaml \
        -f /tmp/gitea_size_values.yaml \
        --set gitea.config.server.ROOT_URL="https://gitea.${DOMAIN}/" \
        --kube-version="${KUBE_VERSION}" | kubectl apply -f -
    
    # Wait for Gitea deployment to be ready
    echo "⏳ Waiting for Gitea deployment to be ready..."
    if kubectl rollout status deploy/gitea -n cf-gitea --timeout=300s; then
        echo "✅ Gitea deployment is ready"
    else
        echo "❌ ERROR: Gitea deployment failed to become ready"
        echo "Check deployment status: kubectl get deployment gitea -n cf-gitea"
        echo "Check logs: kubectl logs -l app=gitea -n cf-gitea"
        exit 1
    fi
    
    # Cleanup temporary files
    rm -f /tmp/gitea_values.yaml /tmp/gitea_size_values.yaml /tmp/merged_values.yaml
    
    echo "✅ Gitea deployed directly and ready for initialization"
}

# Initialize Gitea after direct deployment
wait_for_gitea_and_initialize() {
    echo ""
    echo "=== Gitea Initialization ==="
    echo "Gitea has been deployed directly - proceeding with initialization..."
    
    # Verify Gitea deployment exists (should already be deployed directly)
    if ! kubectl get deployment gitea -n cf-gitea >/dev/null 2>&1; then
        echo "❌ ERROR: Gitea deployment not found"
        echo "   This should not happen - deploy_gitea_directly should have created it"
        exit 1
    fi
    
    echo "✅ Gitea Deployment confirmed"
    
    # Gitea should already be ready from direct deployment, but double-check
    echo "⏳ Verifying Gitea is ready..."
    if ! kubectl rollout status deploy/gitea -n cf-gitea --timeout=60s; then
        echo "❌ ERROR: Gitea deployment not ready"
        echo "   Check deployment status: kubectl get deployment gitea -n cf-gitea"
        echo "   Check logs: kubectl logs -l app=gitea -n cf-gitea"
        exit 1
    fi
    
    echo "✅ Gitea is ready for initialization"
    
    # Now run the Gitea initialization (extracted from original bootstrap.sh)
    echo ""
    echo "📦 Running Gitea initialization..."
    
    # Check if yq is available for value extraction (needed for init)
    if command -v yq >/dev/null 2>&1; then
        YQ_CMD="yq"
    elif [ -f "$HOME/yq" ]; then
        YQ_CMD="$HOME/yq"
    else
        echo "ERROR: yq not found. Gitea initialization requires yq."
        echo "Without Gitea initialization, ArgoCD will not have git repositories!"
        exit 1
    fi
    
    # Generate admin password function (from original bootstrap.sh)
    generate_password() {
        openssl rand -hex 16 | tr 'a-f' 'A-F' | head -c 32
    }
    
    # Extract Gitea values for initialization
    echo "Extracting Gitea values for initialization..."
    $YQ_CMD eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > /tmp/gitea_values.yaml
    $YQ_CMD eval '.apps.gitea.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/gitea_size_values.yaml
    
    # Create merged values configmap (needed by gitea-init-job)
    echo "Creating initial-cf-values configmap..."
    
    # Recreate merged values like original bootstrap (needed for gitea-init-job)
    local SIZE_VALUES_FILE="values_${CLUSTER_SIZE}.yaml"
    if [ -n "$SIZE_VALUES_FILE" ]; then
        # Merge base values with size-specific overrides  
        VALUES=$($YQ_CMD eval-all '. as $item ireduce ({}; . * $item)' \
            "${SOURCE_ROOT}/root/${VALUES_FILE}" \
            "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" | \
            $YQ_CMD eval ".global.domain = \"${DOMAIN}\"")
    else
        # Use base values only
        VALUES=$(cat "${SOURCE_ROOT}/root/${VALUES_FILE}" | $YQ_CMD ".global.domain = \"${DOMAIN}\"")
    fi
    
    # Apply the target revision override
    VALUES=$(echo "$VALUES" | $YQ_CMD eval ".clusterForge.targetRevision = \"${TARGET_REVISION}\"")
    
    kubectl create configmap initial-cf-values --from-literal=initial-cf-values="$VALUES" --dry-run=client -o yaml | kubectl apply -n cf-gitea -f -
    
    # Create Gitea admin credentials
    echo "Creating Gitea admin credentials..."
    kubectl create secret generic gitea-admin-credentials \
      --namespace=cf-gitea \
      --from-literal=username=silogen-admin \
      --from-literal=password=$(generate_password) \
      --dry-run=client -o yaml | kubectl apply -f -
    
    # Run Gitea initialization job
    echo "Deploying Gitea initialization job..."
    helm template --release-name gitea-init "${SOURCE_ROOT}/scripts/init-gitea-job" \
      --set clusterSize="${SIZE_VALUES_FILE}" \
      --set domain="${DOMAIN}" \
      --set targetRevision="${TARGET_REVISION}" \
      --kube-version="${KUBE_VERSION}" | kubectl apply -f -
      
    # Wait for initialization to complete
    echo "⏳ Waiting for Gitea initialization to complete..."
    if kubectl wait --for=condition=complete --timeout=300s job/gitea-init-job -n cf-gitea; then
        echo "✅ Gitea initialization completed successfully"
        echo "📦 Git repositories are now available for ArgoCD"
    else
        echo "❌ ERROR: Gitea initialization timed out or failed"
        echo "   This is CRITICAL - ArgoCD needs git repositories to function!"
        echo "   Check job status: kubectl describe job gitea-init-job -n cf-gitea" 
        echo "   Check logs: kubectl logs -l job-name=gitea-init-job -n cf-gitea"
        exit 1
    fi
    
    # Cleanup temporary files
    rm -f /tmp/gitea_values.yaml /tmp/gitea_size_values.yaml
    
    echo "📦 Gitea initialization phase complete"
}

# Wait for OpenBao to be deployed by ArgoCD and run initialization
wait_for_openbao_and_initialize() {
    echo ""
    echo "=== OpenBao Initialization ==="
    echo "Waiting for ArgoCD to deploy OpenBao..."
    
    # Wait for OpenBao StatefulSet to exist (deployed by ArgoCD)
    echo "⏳ Waiting for OpenBao StatefulSet to be created by ArgoCD..."
    local timeout=300
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl get statefulset openbao -n cf-openbao >/dev/null 2>&1; then
            echo "✅ OpenBao StatefulSet found"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "   Waiting for ArgoCD to create OpenBao StatefulSet... ($elapsed/$timeout seconds)"
    done
    
    if [ $elapsed -ge $timeout ]; then
        echo "⚠️  WARNING: OpenBao StatefulSet not found after $timeout seconds"
        echo "   ArgoCD may still be syncing. OpenBao init will be skipped."
        echo "   You may need to run OpenBao initialization manually later."
        return
    fi
    
    # Wait for OpenBao to be running
    echo "⏳ Waiting for OpenBao pod to be ready..."
    if kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n cf-openbao --timeout=300s; then
        echo "✅ OpenBao is running"
    else
        echo "⚠️  WARNING: OpenBao pod not ready within timeout"
        echo "   OpenBao initialization will be skipped."
        return
    fi
    
    # Now run the OpenBao initialization (extracted from original bootstrap.sh)
    echo ""
    echo "🔐 Running OpenBao initialization..."
    
    # Check if yq is available for value extraction (needed for init)
    if command -v yq >/dev/null 2>&1; then
        YQ_CMD="yq"
    elif [ -f "$HOME/yq" ]; then
        YQ_CMD="$HOME/yq"
    else
        echo "WARNING: yq not found. Skipping OpenBao initialization."
        echo "You may need to initialize OpenBao manually."
        return
    fi
    
    # Extract OpenBao values for initialization (reusing existing logic)
    echo "Extracting OpenBao values for initialization..."
    $YQ_CMD eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${VALUES_FILE}" > /tmp/openbao_values.yaml
    $YQ_CMD eval '.apps.openbao.valuesObject' "${SOURCE_ROOT}/root/${SIZE_VALUES_FILE}" > /tmp/openbao_size_values.yaml
    
    # Create initial secrets config for init job (separate from ArgoCD-managed version)
    echo "Creating initial OpenBao secrets configuration..."
    cat "${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-manager-cm.yaml" | \
      sed "s|name: openbao-secret-manager-scripts|name: openbao-secret-manager-scripts-init|g" | kubectl apply -f -

    cat "${SOURCE_ROOT}/sources/openbao-config/0.1.0/templates/openbao-secret-definitions.yaml" | \
      sed "s|{{ .Values.domain }}|${DOMAIN}|g" | \
      sed "s|name: openbao-secrets-config|name: openbao-secrets-init-config|g" | kubectl apply -f -

    # Run OpenBao initialization job
    echo "Deploying OpenBao initialization job..."
    helm template --release-name openbao-init "${SOURCE_ROOT}/scripts/init-openbao-job" \
      -f /tmp/openbao_values.yaml \
      --set domain="${DOMAIN}" \
      --kube-version="${KUBE_VERSION}" | kubectl apply -f -
      
    # Wait for initialization to complete
    echo "⏳ Waiting for OpenBao initialization to complete..."
    if kubectl wait --for=condition=complete --timeout=300s job/openbao-init-job -n cf-openbao; then
        echo "✅ OpenBao initialization completed successfully"
    else
        echo "⚠️  WARNING: OpenBao initialization timed out or failed"
        echo "   Check job status: kubectl describe job openbao-init-job -n cf-openbao"
        echo "   Check logs: kubectl logs -l job-name=openbao-init-job -n cf-openbao"
    fi
    
    # Cleanup temporary files
    rm -f /tmp/openbao_values.yaml /tmp/openbao_size_values.yaml
    
    echo "🔐 OpenBao initialization phase complete"
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
    echo "  4. ArgoCD is syncing apps from target revision: $TARGET_REVISION"
    echo "     (Only apps enabled in that revision will be deployed)"
    echo "  5. Gitea provides git repositories: https://gitea.${DOMAIN}"
    echo "  6. Essential infrastructure (Gitea, OpenBao) is initialized"
    echo ""
    echo "🧹 Cleanup: Bootstrap manifests saved at:"
    echo "   - /tmp/cluster-forge-bootstrap.yaml (all apps rendered)"
    echo "   - /tmp/cluster-forge-parent-app.yaml (parent app only)"
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
    
    # NEW APPROACH: Render locally, but only bootstrap ArgoCD + parent app
    render_cluster_forge_manifests
    bootstrap_argocd_managed_approach
    
    # Show final status
    show_bootstrap_summary
}

# Execute main function
main