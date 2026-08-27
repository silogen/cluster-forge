#!/usr/bin/env bash
# Offline tests for install helpers (no cluster required).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

test_help_exits_zero() {
  local script="$1"
  "${script}" --help >/dev/null
  pass "${script} --help"
}

test_help_exits_zero scripts/ai-gateway-webhook-health.sh
test_help_exits_zero scripts/platform-gates/run-all.sh

unknown_arg_status=0
scripts/ai-gateway-webhook-health.sh --not-a-flag >/dev/null 2>&1 || unknown_arg_status=$?
[[ "${unknown_arg_status}" -eq 2 ]] || fail "ai-gateway-webhook-health.sh unknown arg should exit 2"
pass "ai-gateway-webhook-health.sh rejects unknown flags"

rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT

helm template test sources/envoy-ai-gateway/v1.0.0 \
  --namespace envoy-ai-gateway-system \
  --set controller.mutatingWebhook.certManager.enable=true \
  > "${rendered}"

grep -q 'kind: MutatingWebhookConfiguration' "${rendered}" \
  || fail "envoy-ai-gateway render missing MutatingWebhookConfiguration"

grep -q 'cert-manager.io/inject-ca-from: envoy-ai-gateway-system/self-signed-cert-for-mutating-webhook' "${rendered}" \
  || fail "envoy-ai-gateway cert-manager path missing inject-ca-from annotation"

grep -q 'kind: Certificate' "${rendered}" \
  || fail "envoy-ai-gateway cert-manager path missing Certificate"

grep -q 'kind: Issuer' "${rendered}" \
  || fail "envoy-ai-gateway cert-manager path missing Issuer"

if grep -E '^[[:space:]]+caBundle:' "${rendered}" >/dev/null; then
  fail "envoy-ai-gateway cert-manager path must not embed clientConfig.caBundle"
fi
pass "envoy-ai-gateway cert-manager webhook path renders Certificate, Issuer, and inject-ca-from"

echo "All script tests passed."
