#!/usr/bin/env bash
# Smoke test for the inference-demo profile. It gets a token from Dex with a
# password grant, calls the AIWB API, deploys the dummy AIMService into the
# workbench namespace and calls the model through the gateway. Set KEEP=1 to
# keep the AIMService. curl -k, because the demo certificate is self-signed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-workbench}"
AIM_TIMEOUT="${AIM_TIMEOUT:-15m}"
CLIENT_ID=aiwb
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
discovery="$(curl -sk "https://auth.$DOMAIN/.well-known/openid-configuration" || true)"
TOKEN_ENDPOINT="$(echo "$discovery" | jq -r '.token_endpoint // ""' 2>/dev/null || true)"
[ -n "$TOKEN_ENDPOINT" ] || fail "no OIDC discovery document at auth.$DOMAIN"
ok "issuer auth.$DOMAIN answers"

echo "== 3. a token for devuser"
secret="$(kubectl get secret dex-credentials -n dex -o jsonpath='{.data.client-secret}' | base64 -d)"
password="$(kubectl get secret dex-credentials -n dex -o jsonpath='{.data.password}' | base64 -d)"
TOKEN="$(curl -skf -X POST "$TOKEN_ENDPOINT" \
  -d grant_type=password -d "client_id=$CLIENT_ID" -d "client_secret=$secret" \
  -d "username=devuser@$DOMAIN" -d "password=$password" -d 'scope=openid email' \
  | jq -r '.access_token // ""')"
[ -n "$TOKEN" ] || fail "the password grant gave no token"
ok "token"

echo "== 4. the API and the UI answer"
api "https://aiwbapi.$DOMAIN/v1/inference/models" | jq -e 'has("data")' >/dev/null \
  || fail "the model catalog call failed"
ok "the API lists the catalog"
curl -skf -o /dev/null "https://aiwbui.$DOMAIN/" || fail "the UI does not answer"
ok "the UI answers"
# The UI sends the browser to the issuer for the login. The CSRF token and
# its cookie must arrive together, so the two calls share a cookie jar.
jar="$(mktemp)"
csrf="$(curl -sk -c "$jar" "https://aiwbui.$DOMAIN/api/auth/csrf" | jq -r '.csrfToken // ""')"
location="$(curl -sk -b "$jar" -c "$jar" -o /dev/null -w '%{redirect_url}' \
  -X POST "https://aiwbui.$DOMAIN/api/auth/signin/oidc" \
  --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=https://aiwbui.$DOMAIN/")"
rm -f "$jar"
case "$location" in
  https://auth.$DOMAIN/auth?*) ok "the UI login goes to the issuer";;
  *) fail "the UI login redirect was '$location'";;
esac

echo "== 5. the dummy service in namespace $NS"
if [ -n "${PULL_SECRET_JSON:-}" ]; then
  kubectl create secret generic aim-pull --namespace "$NS" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$PULL_SECRET_JSON" \
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
