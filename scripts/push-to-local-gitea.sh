#!/bin/bash
# Push current branch to local Gitea instance

set -e

echo "📤 Pushing to local Gitea..."

# Get Gitea credentials
GITEA_USER=$(kubectl get secret gitea-admin-credentials -n cf-gitea -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(kubectl get secret gitea-admin-credentials -n cf-gitea -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$GITEA_USER" ] || [ -z "$GITEA_PASS" ]; then
    echo "❌ ERROR: Could not retrieve Gitea credentials from cluster"
    exit 1
fi

# Port-forward Gitea
echo "🔌 Starting port-forward to Gitea..."
kubectl port-forward -n cf-gitea svc/gitea-http 3000:3000 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up..."
    kill $PF_PID 2>/dev/null || true
    git remote remove gitea-local 2>/dev/null || true
}

trap cleanup EXIT

# Add remote
git remote remove gitea-local 2>/dev/null || true
git remote add gitea-local "http://${GITEA_USER}:${GITEA_PASS}@localhost:3000/cluster-org/cluster-forge.git"

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)

# Push
echo "⬆️  Pushing ${CURRENT_BRANCH} to gitea-local:main..."
git push gitea-local HEAD:main --force

echo "✅ Successfully pushed to local Gitea!"
echo "📝 ArgoCD will automatically sync changes within a few minutes"
echo "    Or manually sync with: kubectl patch application <app-name> -n argocd -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"normal\"}}}' --type merge"
