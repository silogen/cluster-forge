#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <repo-path> <gitea-org> <gitea-repo-name>"
    echo "Example: $0 /path/to/silogen-core cluster-org core"
    exit 1
fi

REPO_PATH="$1"
GITEA_ORG="${2:-cluster-org}"
GITEA_REPO="${3:-$(basename "$REPO_PATH")}"

echo "📤 Pushing $REPO_PATH to $GITEA_ORG/$GITEA_REPO in local Gitea..."

# Start port-forward to Gitea in background
echo "🔌 Starting port-forward to Gitea..."
kubectl port-forward -n cf-gitea svc/gitea-http 3000:3000 > /dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for port-forward
sleep 2

# Get Gitea credentials
GITEA_USER=$(kubectl get secret -n cf-gitea gitea-admin-credentials -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(kubectl get secret -n cf-gitea gitea-admin-credentials -o jsonpath='{.data.password}' | base64 -d)

# Create repository in Gitea if it doesn't exist
echo "📦 Ensuring repository exists in Gitea..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    "http://localhost:3000/api/v1/repos/${GITEA_ORG}/${GITEA_REPO}")

if [ "$HTTP_CODE" = "404" ]; then
    echo "   Creating repository ${GITEA_ORG}/${GITEA_REPO}..."
    curl -s -X POST \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${GITEA_REPO}\",\"private\":false}" \
        "http://localhost:3000/api/v1/orgs/${GITEA_ORG}/repos" > /dev/null
    echo "   ✓ Repository created"
else
    echo "   ✓ Repository already exists"
fi

cd "$REPO_PATH"

# Remove existing gitea-local remote if present to ensure fresh credentials
git remote remove gitea-local 2>/dev/null || true

# Add gitea-local remote with credentials
git remote add gitea-local "http://${GITEA_USER}:${GITEA_PASS}@localhost:3000/${GITEA_ORG}/${GITEA_REPO}.git"

# Force push current HEAD to main branch
echo "⬆️  Pushing to $GITEA_ORG/$GITEA_REPO..."
git push gitea-local HEAD:refs/heads/main --force

echo "✅ Successfully pushed to $GITEA_ORG/$GITEA_REPO!"
echo "📝 Use repoURL: http://gitea-http.cf-gitea.svc:3000/${GITEA_ORG}/${GITEA_REPO}.git in your values"
