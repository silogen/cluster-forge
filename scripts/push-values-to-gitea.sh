#!/bin/bash

set -e

echo "📤 Pushing values to cluster-values repo in local Gitea..."

# Get Gitea credentials
GITEA_USER=$(kubectl get secret -n cf-gitea gitea-admin-credentials -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASSWORD=$(kubectl get secret -n cf-gitea gitea-admin-credentials -o jsonpath='{.data.password}' | base64 -d)

# Start port-forward in background
echo "🔌 Starting port-forward to Gitea..."
kubectl port-forward -n cf-gitea svc/gitea-http 3000:3000 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Function to cleanup
cleanup() {
    echo "🧹 Cleaning up..."
    kill $PORT_FORWARD_PID 2>/dev/null || true
    cd "$ORIGINAL_DIR"
    rm -rf /tmp/cluster-values-local 2>/dev/null || true
}

# Trap cleanup on exit
trap cleanup EXIT

ORIGINAL_DIR=$(pwd)

# Clone the cluster-values repo
echo "📥 Cloning cluster-values repo..."
rm -rf /tmp/cluster-values-local
git clone "http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:3000/cluster-org/cluster-values.git" /tmp/cluster-values-local

# Copy the values file
echo "📝 Copying values_local_kind.yaml..."
cp root/values_local_kind.yaml /tmp/cluster-values-local/

# Commit and push
cd /tmp/cluster-values-local
git config user.email "dev@localhost.local"
git config user.name "Local Dev"
git add values_local_kind.yaml

if git diff --staged --quiet; then
    echo "ℹ️  No changes to push"
    exit 0
fi

git commit -m "Update values_local_kind.yaml with localDev parameter"

echo "⬆️  Pushing to cluster-values repo..."
git push origin main

echo "✅ Successfully pushed to cluster-values repo!"
echo "📝 ArgoCD will automatically sync changes within a few minutes"
echo "    Or manually sync with: kubectl patch application cluster-forge -n argocd -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"normal\"}}}' --type merge"
