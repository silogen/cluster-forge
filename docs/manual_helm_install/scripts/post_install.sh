#!/bin/bash

# Post-installation script for AIWB
# Configures URLs and Keycloak redirect URIs for the target domain.
#
# Usage:
#   ./post_install.sh                          # localhost (port-forward mode)
#   DOMAIN=mynode.example.com ./post_install.sh  # remote domain (Gateway mode)

set -euo pipefail

DOMAIN="${DOMAIN:-localhost}"

# Derive protocol-aware URLs from DOMAIN, matching the logic in install_base.sh.
if [ "${DOMAIN}" = "localhost" ]; then
  # Port-forward mode: AIWB-UI on 18000, Keycloak on 18080
  AIWB_URL="http://localhost:18000"
  KC_URL="http://localhost:18080"
  KC_HOSTNAME="http://localhost:18080"
  USE_PORT_FORWARD=true
  TOTAL_STEPS=6
else
  # Gateway mode: traffic routed via subdomain through the Gateway LoadBalancer
  AIWB_URL="https://aiwbui.${DOMAIN}"
  KC_URL="https://kc.${DOMAIN}"
  KC_HOSTNAME="https://kc.${DOMAIN}"
  USE_PORT_FORWARD=false
  TOTAL_STEPS=4
fi

echo "🔧 AIWB Post-Install Setup"
echo "================================"
echo ""
if [ "${USE_PORT_FORWARD}" = true ]; then
  echo "Mode: localhost (port-forward)"
  echo "Access AIWB at: ${AIWB_URL}"
else
  echo "Mode: remote domain (${DOMAIN})"
  echo "Access AIWB at: ${AIWB_URL}"
fi
echo ""

STEP=1

# ============================================================================
# Step: Start port-forwards (localhost only)
# ============================================================================
if [ "${USE_PORT_FORWARD}" = true ]; then
  echo "📡 Step ${STEP}/${TOTAL_STEPS}: Starting port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 2

  kubectl port-forward -n aiwb --address 0.0.0.0 svc/aiwb-ui 18000:8000 &
  AIWB_PF_PID=$!
  kubectl port-forward -n keycloak --address 0.0.0.0 svc/keycloak 18080:8080 &
  KC_PF_PID=$!

  echo "  ✅ Port-forwards started (PIDs: $AIWB_PF_PID, $KC_PF_PID)"
  sleep 3
  STEP=$((STEP + 1))
fi

# ============================================================================
# Step: Update AIWB environment variables
# ============================================================================
echo "📝 Step ${STEP}/${TOTAL_STEPS}: Updating AIWB environment variables..."
kubectl set env deployment/aiwb-ui -n aiwb \
  NEXTAUTH_URL="${AIWB_URL}" \
  KEYCLOAK_ISSUER="${KC_URL}/realms/airm"
echo "  ✅ AIWB environment variables updated"
STEP=$((STEP + 1))

# ============================================================================
# Step: Update Keycloak hostname
# ============================================================================
echo "📝 Step ${STEP}/${TOTAL_STEPS}: Updating Keycloak hostname..."
kubectl set env deployment/keycloak -n keycloak \
  KC_HOSTNAME="${KC_HOSTNAME}"
echo "  ✅ Keycloak hostname updated"
STEP=$((STEP + 1))

# ============================================================================
# Step: Wait for pods to restart
# ============================================================================
echo "⏳ Step ${STEP}/${TOTAL_STEPS}: Waiting for pods to restart..."
echo "  - AIWB UI..."
kubectl rollout status deployment/aiwb-ui -n aiwb --timeout=180s
echo "  - Keycloak..."
kubectl rollout status deployment/keycloak -n keycloak --timeout=180s
echo "  ✅ Pods restarted"
STEP=$((STEP + 1))

# ============================================================================
# Step: Restart port-forwards (localhost only — pods restarted above)
# ============================================================================
if [ "${USE_PORT_FORWARD}" = true ]; then
  echo "📡 Step ${STEP}/${TOTAL_STEPS}: Restarting port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 2

  kubectl port-forward -n aiwb --address 0.0.0.0 svc/aiwb-ui 18000:8000 &
  AIWB_PF_PID=$!
  kubectl port-forward -n keycloak --address 0.0.0.0 svc/keycloak 18080:8080 &
  KC_PF_PID=$!

  echo "  ✅ Port-forwards restarted (PIDs: $AIWB_PF_PID, $KC_PF_PID)"
  sleep 5
  STEP=$((STEP + 1))
fi

# ============================================================================
# Step: Update Keycloak client redirect URIs
# ============================================================================
echo "🔐 Step ${STEP}/${TOTAL_STEPS}: Updating Keycloak client redirect URIs..."

# Get admin token
KC_ADMIN_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
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
  echo "  1. Go to ${KC_URL}/admin"
  echo "  2. Login with: silogen-admin / placeholder"
  echo "  3. Go to Clients > aiwb-ui-client"
  echo "  4. Add to Valid redirect URIs: ${AIWB_URL}/*"
  exit 1
fi

# Get current client configuration
CURRENT_CLIENT=$(curl -s -X GET \
  "${KC_URL}/admin/realms/airm/clients/ceeab688-00ab-4d0f-b0e2-0b5b0f1facbe" \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN")

# Update redirect URIs
echo "$CURRENT_CLIENT" | \
  jq --arg uri "${AIWB_URL}/*" '.redirectUris += [$uri] | .redirectUris |= unique' | \
curl -s -X PUT \
  "${KC_URL}/admin/realms/airm/clients/ceeab688-00ab-4d0f-b0e2-0b5b0f1facbe" \
  -H "Authorization: Bearer $KC_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d @-

echo "  ✅ Keycloak redirect URIs updated"
echo ""

# ============================================================================
# Success
# ============================================================================
echo "✅ Setup Complete!"
echo "================================"
echo ""
echo "🌐 Access AIWB from your browser:"
echo "   URL: ${AIWB_URL}"
echo ""
echo "🔑 Login credentials:"
echo "   Username: devuser@${DOMAIN}"
echo "   Password: placeholder"
echo ""

if [ "${USE_PORT_FORWARD}" = true ]; then
  echo "📊 Port-forwards running in background:"
  echo "   - AIWB UI: localhost:18000 → aiwb-ui:8000 (PID: $AIWB_PF_PID)"
  echo "   - Keycloak: localhost:18080 → keycloak:8080 (PID: $KC_PF_PID)"
  echo ""
  echo "💡 To stop port-forwards:"
  echo "   pkill -f 'kubectl port-forward'"
  echo ""
else
  GATEWAY_IP=$(kubectl get gateway https -n kgateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")
  echo "💡 Ensure DNS points these names to the Gateway IP (${GATEWAY_IP}):"
  echo "   aiwbui.${DOMAIN}"
  echo "   aiwbapi.${DOMAIN}"
  echo "   kc.${DOMAIN}"
  echo ""
fi

echo "💡 Keycloak Admin Console: ${KC_URL}/admin"
echo ""
