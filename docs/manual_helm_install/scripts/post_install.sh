#!/bin/bash

# Post-installation script for localhost development setup
# This configures AIWB to be accessible via localhost
# Run this AFTER install_base.sh completes successfully

set -euo pipefail

echo "🔧 AIWB Localhost Setup"
echo "================================"
echo ""
echo "This script will configure AIWB for access via localhost."
echo "After completion, access AIWB at: http://localhost:18000"
echo ""

# Step 1: Start port-forwards
echo "📡 Step 1/6: Starting port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2

kubectl port-forward -n aiwb --address 0.0.0.0 svc/aiwb-ui 18000:8000 &
AIWB_PF_PID=$!
kubectl port-forward -n keycloak --address 0.0.0.0 svc/keycloak 18080:8080 &
KC_PF_PID=$!

echo "  ✅ Port-forwards started (PIDs: $AIWB_PF_PID, $KC_PF_PID)"
sleep 3

# Step 2: Update AIWB environment variables
echo "📝 Step 2/6: Updating AIWB environment variables..."
kubectl set env deployment/aiwb-ui -n aiwb \
  NEXTAUTH_URL=http://localhost:18000 \
  KEYCLOAK_ISSUER=http://localhost:18080/realms/airm
echo "  ✅ AIWB environment variables updated"

# Step 3: Update Keycloak hostname
echo "📝 Step 3/6: Updating Keycloak hostname..."
kubectl set env deployment/keycloak -n keycloak \
  KC_HOSTNAME=http://localhost:18080
echo "  ✅ Keycloak hostname updated"

# Step 4: Wait for pods to restart
echo "⏳ Step 4/6: Waiting for pods to restart..."
echo "  - AIWB UI..."
kubectl rollout status deployment/aiwb-ui -n aiwb --timeout=180s
echo "  - Keycloak..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=180s
echo "  ✅ Pods restarted"

# Step 5: Restart port-forwards (pods restarted with new ports)
echo "📡 Step 5/6: Restarting port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2

kubectl port-forward -n aiwb --address 0.0.0.0 svc/aiwb-ui 18000:8000 &
AIWB_PF_PID=$!
kubectl port-forward -n keycloak --address 0.0.0.0 svc/keycloak 18080:8080 &
KC_PF_PID=$!

echo "  ✅ Port-forwards restarted (PIDs: $AIWB_PF_PID, $KC_PF_PID)"
sleep 5

# Step 6: Update Keycloak client redirect URIs
echo "🔐 Step 6/6: Updating Keycloak client redirect URIs..."

# Get admin token
KC_ADMIN_TOKEN=$(curl -s -X POST 'http://localhost:18080/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=silogen-admin' \
  -d 'password=placeholder' \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli' | jq -r '.access_token')

if [ "$KC_ADMIN_TOKEN" = "null" ] || [ -z "$KC_ADMIN_TOKEN" ]; then
  echo "  ⚠️  Failed to get Keycloak admin token. Keycloak may not be ready yet."
  echo "  You can run this script again in a few minutes, or manually update redirect URIs."
  echo ""
  echo "To manually update:"
  echo "  1. Go to http://localhost:18080/admin"
  echo "  2. Login with: silogen-admin / placeholder"
  echo "  3. Go to Clients > aiwb-ui-client"
  echo "  4. Add to Valid redirect URIs: http://localhost:18000/*"
  exit 1
fi

# Get current client configuration
CURRENT_CLIENT=$(curl -s -X GET \
  "http://localhost:18080/admin/realms/airm/clients/ceeab688-00ab-4d0f-b0e2-0b5b0f1facbe" \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN")

# Update redirect URIs
echo "$CURRENT_CLIENT" | \
  jq '.redirectUris += ["http://localhost:18000/*"] | .redirectUris |= unique' | \
curl -s -X PUT \
  "http://localhost:18080/admin/realms/airm/clients/ceeab688-00ab-4d0f-b0e2-0b5b0f1facbe" \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @-

echo "  ✅ Keycloak redirect URIs updated"
echo ""

# Success message
echo "✅ Localhost Setup Complete!"
echo "================================"
echo ""
echo "🌐 Access AIWB from your browser:"
echo "   URL: http://localhost:18000"
echo ""
echo "🔑 Login credentials:"
echo "   Username: devuser@localhost"
echo "   Password: placeholder"
echo ""
echo "📊 Port-forwards running in background:"
echo "   - AIWB UI: localhost:18000 → aiwb-ui:8000 (PID: $AIWB_PF_PID)"
echo "   - Keycloak: localhost:18080 → keycloak:8080 (PID: $KC_PF_PID)"
echo ""
echo "💡 To stop port-forwards:"
echo "   pkill -f 'kubectl port-forward'"
echo ""
echo "📝 For more information, see internal/DEV_INSTRUCTIONS.md"
echo ""
