#!/bin/bash
set -e

# =============================================================================
# Cluster-Forge Update Script
# =============================================================================
# This script performs a complete update of Cluster-Forge, including:
# - Database backups
# - Application removal
# - Cluster-Forge reinstallation
# - Database restoration
#
# Usage: ./update.sh [VERSION]
#   VERSION: Git tag/version to checkout (e.g., v1.5.0, v1.6.0)
#            If not provided, will use v1.5.0 as default
# =============================================================================

# Check for version argument
VERSION=${1:-v1.5.0}
echo "Using Cluster-Forge version: $VERSION"

# Global variables
export CURRENT_DATE=$(date +%Y-%m-%d)
export AIRM_DB_FILE=$HOME/airm_db_backup_$CURRENT_DATE.sql
export KEYCLOAK_DB_FILE=$HOME/keycloak_db_backup_$CURRENT_DATE.sql
ARGO_VERSION=v3.2.0

# =============================================================================
# Function: install_dependencies
# Description: Installs required tools (argocd, yq, helm, postgresql-client)
# =============================================================================
install_dependencies() {
    echo "Installing dependencies..."
    
    # Install ArgoCD CLI
    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/$ARGO_VERSION/argocd-linux-amd64
    chmod +x argocd
    sudo mv argocd /usr/local/bin/
    
    # Install yq, helm, and postgresql-client
    sudo snap install yq --classic
    sudo snap install helm --classic
    sudo apt install postgresql-client
    
    echo "Dependencies installed successfully."
}

# =============================================================================
# Function: get_db_credentials
# Description: Retrieves database credentials from Kubernetes secrets
# =============================================================================
get_db_credentials() {
    echo "Retrieving database credentials..."
    
    export AIRM_DB_USERNAME=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.username}' | base64 --decode)
    export AIRM_DB_PASSWORD=$(kubectl get secret airm-cnpg-user -n airm -o jsonpath='{.data.password}' | base64 --decode)
    
    export KEYCLOAK_DB_USERNAME=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.username}' | base64 --decode)
    export KEYCLOAK_DB_PASSWORD=$(kubectl get secret keycloak-cnpg-user -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
    
    echo "Database credentials retrieved successfully."
}

# =============================================================================
# Function: backup_databases
# Description: Backs up AIRM and Keycloak databases
# =============================================================================
backup_databases() {
    echo "Backing up databases..."
    
    # Backup AIRM database
    echo "Backing up AIRM database to $AIRM_DB_FILE..."
    export PGPASSWORD=$AIRM_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $AIRM_DB_USERNAME airm > $AIRM_DB_FILE
    unset PGPASSWORD
    echo "AIRM database backup completed."
    
    # Backup Keycloak database
    echo "Backing up Keycloak database to $KEYCLOAK_DB_FILE..."
    export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
    pg_dump --clean -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak > $KEYCLOAK_DB_FILE
    unset PGPASSWORD
    echo "Keycloak database backup completed."
    
    # TODO: backup RMQ data https://www.rabbitmq.com/docs/backup (Akshay for details)
}

# =============================================================================
# Function: disable_clusterforge_autosync
# Description: Turns off Clusterforge auto-sync
# =============================================================================
disable_clusterforge_autosync() {
    echo "Disabling Clusterforge auto-sync..."
    argocd app set clusterforge --sync-policy ""
    argocd app set clusterforge --sync-policy automated --self-heal --prune
    echo "Clusterforge auto-sync disabled."
}

# =============================================================================
# Function: remove_applications
# Description: Removes all applications and namespaces
# =============================================================================
remove_applications() {
    echo "Removing applications and namespaces..."
    
    # Remove AIRM
    echo "Removing AIRM..."
    argocd app delete airm
    kubectl delete namespace airm
    
    # Remove Keycloak
    echo "Removing Keycloak..."
    argocd app delete keycloak
    argocd app delete keycloak-config
    kubectl delete namespace keycloak
    
    # Remove OpenTelemetry
    echo "Removing OpenTelemetry..."
    argocd app delete otel-lgtm
    argocd app delete opentelemetry-operator
    
    # Config-updater
    echo "Removing config-updater..."
    argocd app delete config-updater
    
    # Kaiwo
    echo "Removing Kaiwo..."
    argocd app delete kaiwo-cluster-config
    argocd app delete kaiwo
    kubectl delete namespace kaiwo
    kubectl delete namespace kaiwo-system
    
    # Minio
    echo "Removing Minio..."
    argocd app delete minio-tenant-k8s-secret
    argocd app delete minio-tenant
    kubectl delete namespace minio-tenant-default
    sleep 15
    kubectl delete namespace minio-operator
    
    # OpenTelemetry namespace
    kubectl delete namespace otel-lgtm-stack
    
    # Kueue
    echo "Removing Kueue..."
    argocd app delete kueue
    kubectl delete namespace kueue-system
    
    # Kyverno
    echo "Removing Kyverno..."
    argocd app delete kyverno
    kubectl delete namespace kyverno
    
    echo "Applications removed."
}

# =============================================================================
# Function: cleanup_webhooks
# Description: Cleans up mutating and validating webhooks
# =============================================================================
cleanup_webhooks() {
    echo "Cleaning up webhooks..."
    
    # Mutating webhooks cleanup
    kubectl delete mutatingwebhookconfigurations/kaiwo-job-mutating
    kubectl delete mutatingwebhookconfigurations/kueue-mutating-webhook-configuration
    kubectl delete mutatingwebhookconfigurations/opentelemetry-operator-mutating-webhook-configuration
    
    # Validating webhooks cleanup
    kubectl delete validatingwebhookconfigurations/kaiwo-job-validating
    kubectl delete validatingwebhookconfigurations/kueue-validating-webhook-configuration
    kubectl delete validatingwebhookconfigurations/opentelemetry-operator-validating-webhook-configuration
    
    echo "Webhooks cleaned up."
}

# =============================================================================
# Function: remove_clusterforge_and_apps
# Description: Removes Clusterforge and remaining Argo CD apps
# =============================================================================
remove_clusterforge_and_apps() {
    echo "Removing Clusterforge and remaining Argo CD apps..."
    
    # Clusterforge
    argocd app delete clusterforge
    
    # Remaining Argo CD apps
    argocd app delete amd-device-config
    argocd app delete amd-gpu-operator
    argocd app delete appwrapper
    argocd app delete certmanager
    argocd app delete cluster-airm-config
    argocd app delete cluster-auto-pvc
    argocd app delete cnpg-operator
    argocd app delete external-secrets
    argocd app delete gateway-api
    argocd app delete k8s-cluster-secret-store
    argocd app delete kgateway
    argocd app delete kgateway-crds
    argocd app delete kuberay-operator
    argocd app delete kyverno
    argocd app delete metallb
    argocd app delete minio-operator
    argocd app delete prometheus-crds
    argocd app delete rabbitmq
    
    echo "Clusterforge and apps removed."
}

# =============================================================================
# Function: cleanup_finalizers_and_webhooks
# Description: Removes finalizers and cleans up remaining webhooks
# =============================================================================
cleanup_finalizers_and_webhooks() {
    echo "Cleaning up finalizers and webhooks..."
    
    # Remove kyverno finalizers
    kubectl patch application/kyverno -p '{"metadata":{"finalizers":[]}}' --type=merge
    
    # Mutate webhooks that were bounced earlier
    kubectl delete mutatingwebhookconfigurations/kyverno-policy-mutating-webhook-cfg
    kubectl delete mutatingwebhookconfigurations/kyverno-resource-mutating-webhook-cfg
    kubectl delete mutatingwebhookconfigurations/kyverno-verify-mutating-webhook-cfg
    
    # Validating webhooks that were bounced earlier
    kubectl delete validatingwebhookconfigurations/kyverno-cel-exception-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-cleanup-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-exception-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-global-context-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-policy-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-resource-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/kyverno-ttl-validating-webhook-cfg
    kubectl delete validatingwebhookconfigurations/secretstore-validate
    
    echo "Finalizers and webhooks cleaned up."
}

# =============================================================================
# Function: force_delete_namespaces
# Description: Forces deletion of stubborn namespaces
# =============================================================================
force_delete_namespaces() {
    echo "Force deleting stubborn namespaces..."
    
    kubectl delete namespace kueue-system --force --grace-period=0
    kubectl delete namespace kyverno --force --grace-period=0
    kubectl delete namespace minio-tenant-default --force --grace-period=0
    kubectl delete namespace otel-lgtm-stack --force --grace-period=0
    
    echo "Namespaces force deleted."
}

# =============================================================================
# Function: cleanup_cluster_resources
# Description: Cleans up clusterqueues and other cluster-level resources
# =============================================================================
cleanup_cluster_resources() {
    echo "Cleaning up cluster resources..."
    
    # Clusterqueues
    kubectl delete clusterqueues/kaiwo --force --grace-period=0
    
    # Clusterqueue finalizer removal
    kubectl patch clusterqueue/kaiwo -p '{"metadata":{"finalizers":[]}}' --type=merge
    
    # Validatingwebhookconfigurations
    kubectl delete validatingwebhookconfigurations/amd-gpu-operator-kmm-validating-webhook-configuration
    kubectl delete validatingwebhookconfigurations/appwrapper-validating-webhook-configuration
    kubectl delete validatingwebhookconfigurations/cert-manager-webhook
    kubectl delete validatingwebhookconfigurations/cnpg-validating-webhook-configuration
    kubectl delete validatingwebhookconfigurations/externalsecret-validate
    kubectl delete validatingwebhookconfigurations/longhorn-webhook-validator
    kubectl delete validatingwebhookconfigurations/metallb-webhook-configuration
    
    kubectl delete mutatingwebhookconfigurations/appwarapper-mutating-webhook-configuration
    kubectl delete mutatingwebhookconfigurations/cert-manager-webhook
    kubectl delete mutatingwebhookconfigurations/cnpg-mutating-webhook-configuration
    kubectl delete mutatingwebhookconfigurations/longhorn-webhook-mutator
    
    # Remove Kueue APIService
    kubectl delete apiservice v1beta1.visibility.kueue.x-k8s.io --force --grace-period=0
    
    # Now able to remove OpenTelemetry namespace
    kubectl delete namespace otel-lgtm-stack
    
    echo "Cluster resources cleaned up."
}

# =============================================================================
# Function: remove_core_namespaces
# Description: Removes remaining core namespaces
# =============================================================================
remove_core_namespaces() {
    echo "Removing core namespaces..."
    
    kubectl delete namespace argocd
    kubectl delete namespace cf-es-backend
    kubectl delete namespace cf-gitea
    
    echo "Core namespaces removed."
}

# =============================================================================
# Function: reinstall_clusterforge
# Description: Reinstalls Clusterforge with the specified version
# =============================================================================
reinstall_clusterforge() {
    echo "Reinstalling Clusterforge version $VERSION..."
    
    # Clone and checkout specific version
    mkdir -p $HOME/cfv2 && cd $HOME/cfv2
    git clone git@github.com:silogen/cluster-forge.git
    cd cluster-forge
    git checkout $VERSION
    cd scripts
    
    # Update Helm values file with the specified version
    yq -i ".clusterforge.targetRevision = \"$VERSION\"" ../root/values.yaml
    
    # Restart Longhorn daemonsets
    kubectl rollout restart daemonset longhorn-manager -n longhorn
    kubectl rollout restart daemonset longhorn-csi-plugin -n longhorn
    kubectl rollout restart daemonset engine-image-ei-c2d50bcc -n longhorn
    
    # Bootstrap cluster
    ./bootstrap.sh silogen-demo.silogen.ai
    
    echo "Clusterforge reinstalled successfully."
}

# =============================================================================
# Function: sync_argocd_apps
# Description: Syncs Argo CD apps
# =============================================================================
sync_argocd_apps() {
    echo "Syncing Argo CD apps..."
    
    argocd app sync appwrapper --force
    argocd app sync clusterforge --force
    argocd app sync kaiwo-crds --force
    argocd app sync prometheus-crds --force
    argocd app sync minio-operator --force
    argocd app sync rabbitmq --force
    
    # Remove Kueue CRDs
    kubectl delete crd/cohorts.kueue.x-k8s.io --force --grace-period=0
    
    # Delete failing sync operation (residue)
    argocd app terminate-op kueue
    
    echo "Argo CD apps synced."
}

# =============================================================================
# Function: wait_for_pod
# Description: Waits for a pod to be in Running state
# Parameters:
#   $1 - Pod name pattern (e.g., "airm-cnpg-1")
#   $2 - Namespace
#   $3 - Timeout in seconds (default: 300)
# =============================================================================
wait_for_pod() {
    local pod_pattern=$1
    local namespace=$2
    local timeout=${3:-300}
    local elapsed=0
    local interval=10
    
    echo "Waiting for pod matching '$pod_pattern' in namespace '$namespace' to be ready..."
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get pods -n $namespace | grep -q "$pod_pattern.*Running"; then
            echo "Pod '$pod_pattern' is running in namespace '$namespace'."
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "Still waiting... (${elapsed}s/${timeout}s)"
    done
    
    echo "ERROR: Timeout waiting for pod '$pod_pattern' in namespace '$namespace'"
    return 1
}

# =============================================================================
# Function: restore_databases
# Description: Restores AIRM and Keycloak databases
# =============================================================================
restore_databases() {
    echo "Restoring databases..."
    
    # Wait for AIRM database pod to be ready
    wait_for_pod "airm-cnpg-1" "airm" 600
    
    # Restore AIRM database
    echo "Restoring AIRM database from $AIRM_DB_FILE..."
    export PGPASSWORD=$AIRM_DB_PASSWORD
    psql -h 127.0.0.1 -U $AIRM_DB_USERNAME airm < $AIRM_DB_FILE
    unset PGPASSWORD
    echo "AIRM database restored successfully."
    
    # Wait for Keycloak database pod to be ready
    wait_for_pod "keycloak-cnpg-1" "keycloak" 600
    
    # Restore Keycloak database
    echo "Restoring Keycloak database from $KEYCLOAK_DB_FILE..."
    export PGPASSWORD=$KEYCLOAK_DB_PASSWORD
    psql -h 127.0.0.1 -U $KEYCLOAK_DB_USERNAME keycloak < $KEYCLOAK_DB_FILE
    unset PGPASSWORD
    echo "Keycloak database restored successfully."
}

# =============================================================================
# Function: verify_database_restore
# Description: Verifies that databases were restored successfully
# =============================================================================
verify_database_restore() {
    echo "Verifying database restore..."
    
    # Check AIRM database pod status
    echo "Checking AIRM database pod status..."
    kubectl get pods -n airm | grep airm-cnpg-1
    kubectl describe pod -n airm -l cnpg.io/cluster=airm-cnpg | grep -A 5 "Status:"
    
    # Check Keycloak database pod status
    echo "Checking Keycloak database pod status..."
    kubectl get pods -n keycloak | grep keycloak-cnpg-1
    kubectl describe pod -n keycloak -l cnpg.io/cluster=keycloak-cnpg | grep -A 5 "Status:"
    
    echo "Database restore verification completed."
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    echo "=========================================="
    echo "Starting Cluster-Forge Update Process"
    echo "Version: $VERSION"
    echo "Date: $(date)"
    echo "=========================================="
    
    # Phase 1: Setup and Backup
    echo ""
    echo "=== Phase 1: Setup and Backup ==="
    install_dependencies
    get_db_credentials
    backup_databases
    
    # Phase 2: Cleanup
    echo ""
    echo "=== Phase 2: Cleanup ==="
    disable_clusterforge_autosync
    remove_applications
    cleanup_webhooks
    remove_clusterforge_and_apps
    cleanup_finalizers_and_webhooks
    force_delete_namespaces
    cleanup_cluster_resources
    remove_core_namespaces
    
    # Phase 3: Reinstall
    echo ""
    echo "=== Phase 3: Reinstall ==="
    reinstall_clusterforge
    sync_argocd_apps
    
    # Phase 4: Get new credentials and restore
    echo ""
    echo "=== Phase 4: Restore ==="
    get_db_credentials  # Get new credentials after reinstall
    restore_databases
    verify_database_restore
    
    echo ""
    echo "=========================================="
    echo "Cluster-Forge Update Completed Successfully!"
    echo "=========================================="
}

# Run main function
main
