#!/usr/bin/env bash
# Smoke test for the aiwb-demo profile. It logs in to Keycloak with a password
# grant, calls the AIWB API, deploys the dummy AIMService into the workbench
# namespace and calls the model through the gateway. Set KEEP=1 to keep the
# AIMService. curl -k, because the demo certificate is self-signed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-workbench}"
AIM_TIMEOUT="${AIM_TIMEOUT:-15m}"
CLIENT_ID=354a0fa1-35ac-4a6d-9c4d-d661129c2cd0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
api() { curl -sk -H "Authorization: Bearer $TOKEN" "$@"; }

echo "== 1. the domain from the gateway"
DOMAIN="$(kubectl get gateway https -n envoy-gateway-system \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}')"
DOMAIN="${DOMAIN#\*.}"
[ -n "$DOMAIN" ] || fail "the https gateway has no hostname"
ok "$DOMAIN"

echo "== 2. the OIDC discovery document"
curl -skf "https://kc.$DOMAIN/realms/airm/.well-known/openid-configuration" \
  | jq -e '.token_endpoint' >/dev/null || fail "no OIDC discovery document"
ok "realm airm answers"

echo "== 3. a token for devuser"
secret="$(kubectl get secret aiwb-ui-keycloak-secret -n aiwb -o jsonpath='{.data.value}' | base64 -d)"
password="$(kubectl get secret airm-realm-credentials -n keycloak \
  -o jsonpath='{.data.KEYCLOAK_INITIAL_DEVUSER_PASSWORD}' | base64 -d)"
TOKEN="$(curl -skf -X POST "https://kc.$DOMAIN/realms/airm/protocol/openid-connect/token" \
  -d grant_type=password -d "client_id=$CLIENT_ID" -d "client_secret=$secret" \
  -d "username=devuser@$DOMAIN" -d "password=$password" -d scope=openid \
  | jq -r '.access_token // ""')"
[ -n "$TOKEN" ] || fail "the password grant gave no token"
ok "token"

echo "== 4. the API and the UI answer"
api "https://aiwbapi.$DOMAIN/v1/inference/models" | jq -e 'has("data")' >/dev/null \
  || fail "the model catalog call failed"
ok "the API lists the catalog"
curl -skf -o /dev/null "https://aiwbui.$DOMAIN/" || fail "the UI does not answer"
ok "the UI answers"

echo "== 5. the dummy service in namespace $NS"
if [ -n "${GHCR_PULL_SECRET_JSON:-}" ]; then
  kubectl create secret generic aim-dummy-pull --namespace "$NS" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$GHCR_PULL_SECRET_JSON" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  NS="$NS" yq '.metadata.namespace = strenv(NS)' "$HERE/aimservice-dummy.yaml" | kubectl apply -f - >/dev/null
else
  NS="$NS" yq 'del(.spec.imagePullSecrets) | .metadata.namespace = strenv(NS)' \
    "$HERE/aimservice-dummy.yaml" | kubectl apply -f - >/dev/null
fi
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  kubectl delete aimservice aim-dummy --namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT
for cond in InferenceServiceReady Ready; do
  if ! kubectl wait --for=condition=$cond aimservice/aim-dummy --namespace "$NS" \
      --timeout="$AIM_TIMEOUT" >/dev/null; then
    kubectl get aimservice aim-dummy --namespace "$NS" -o json \
      | jq -r '.status.conditions[] | "  \(.type)=\(.status) \(.reason): \(.message)"' >&2
    fail "condition $cond did not become true"
  fi
  ok "$cond"
done

echo "== 6. the API lists the deployment"
# The Kyverno policy of the aiwb chart gives the AIMService its workload-id
# label. Without the label the AIWB syncer skips the service.
found=no
for _ in $(seq 1 30); do
  if api "https://aiwbapi.$DOMAIN/v1/projects/$NS/inference" \
      | jq -e '.data | map(select(.metadata.name == "aim-dummy")) | length > 0' >/dev/null 2>&1; then
    found=yes; break
  fi
  sleep 5
done
[ "$found" = yes ] || fail "the API does not list the dummy deployment"
ok "the API lists aim-dummy"

echo "== 7. the model answers through the gateway"
workload="$(kubectl get aimservice aim-dummy --namespace "$NS" \
  -o jsonpath='{.metadata.labels.airm\.silogen\.ai/workload-id}')"
[ -n "$workload" ] || fail "the AIMService has no workload-id label"
url="https://workloads.$DOMAIN/$NS/$workload/v1/chat/completions"
body=""
for _ in $(seq 1 30); do
  body="$(curl -sk -X POST "$url" -H 'Content-Type: application/json' \
    -d '{"model":"sshleifer/tiny-gpt2","messages":[{"role":"user","content":"hi"}],"max_tokens":4}')"
  echo "$body" | jq -e '.choices | length > 0' >/dev/null 2>&1 && break
  sleep 5
done
echo "$body" | jq -e '.choices | length > 0' >/dev/null \
  || { echo "$body" | head -c 500 >&2; fail "no chat completion through $url"; }
ok "chat completion through the gateway"

echo "UI SMOKE TEST PASSED"
