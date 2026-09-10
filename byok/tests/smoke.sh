#!/usr/bin/env bash
# Smoke test for the scalable-inference profile. Run it against the cluster
# after bootstrap.sh install. Set KEEP=1 to keep the test namespace.
# On an aiwb-demo cluster run it with NAMESPACE=workbench: routing is on
# there, and an AIMService in a namespace without the project-id label gets
# no workload-id label and a routing error.
# The dummy image is public. Set GHCR_PULL_SECRET_JSON to a docker config
# JSON when your cluster needs credentials for ghcr.io.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-aims-test}"
AIM_TIMEOUT="${AIM_TIMEOUT:-15m}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

echo "== 1. the controllers are available"
# Not "pod --all": the catalog runs short-lived model discovery pods.
for ns in cert-manager kserve-system aim-system; do
  kubectl wait --for=condition=Available deployment --all --namespace "$ns" --timeout=5m >/dev/null \
    || fail "deployments in $ns are not available"
  ok "$ns"
done

echo "== 2. AIM CRDs"
count="$(kubectl get crd -o name | grep -c 'aim\.eai\.amd\.com$' || true)"
[ "$count" -eq 15 ] || fail "expected 15 AIM CRDs, found $count"
ok "15 AIM CRDs"

echo "== 3. AIMClusterRuntimeConfig default"
kubectl get aimclusterruntimeconfig default >/dev/null || fail "no AIMClusterRuntimeConfig default"
ok "AIMClusterRuntimeConfig default"

echo "== 4. test namespace"
# The aiwb chart owns the workbench namespace, so do not apply over it.
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
if [ -n "${GHCR_PULL_SECRET_JSON:-}" ]; then
  kubectl create secret generic aim-dummy-pull --namespace "$NS" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$GHCR_PULL_SECRET_JSON" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "pull secret"
else
  echo "GHCR_PULL_SECRET_JSON is not set, the image is pulled without credentials"
fi

echo "== 5. apply the dummy service"
# aim-engine fails the model when a named pull secret does not exist, so the
# reference stays only when the secret was made in step 4.
if [ -n "${GHCR_PULL_SECRET_JSON:-}" ]; then
  NS="$NS" yq '.metadata.namespace = strenv(NS)' "$HERE/aimservice-dummy.yaml" | kubectl apply -f - >/dev/null
else
  NS="$NS" yq 'del(.spec.imagePullSecrets) | .metadata.namespace = strenv(NS)' \
    "$HERE/aimservice-dummy.yaml" | kubectl apply -f - >/dev/null
fi

echo "== 6. wait for the service"
# aim-engine 0.2.5 sets ModelReady, TemplateReady, RuntimeConfigReady,
# CacheReady, InferenceServiceReady and Ready. There is no RuntimeReady.
for cond in InferenceServiceReady Ready; do
  if ! kubectl wait --for=condition=$cond aimservice/aim-dummy --namespace "$NS" \
      --timeout="$AIM_TIMEOUT" >/dev/null; then
    kubectl get aimservice aim-dummy --namespace "$NS" -o json \
      | jq -r '.status.conditions[] | "  \(.type)=\(.status) \(.reason): \(.message)"' >&2
    fail "condition $cond did not become true"
  fi
  ok "$cond"
done

echo "== 7. call the model"
# The InferenceService name carries a suffix, so select by the AIMService name.
svc="$(kubectl get svc --namespace "$NS" \
  -l aim.eai.amd.com/service.name=aim-dummy,component=predictor -o name | head -n1)"
[ -n "$svc" ] || fail "no predictor service found"
kubectl port-forward --namespace "$NS" "$svc" 18080:80 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf -o /dev/null "http://127.0.0.1:18080/v1/models" && break
  sleep 2
done
body="$(curl -sf -X POST "http://127.0.0.1:18080/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"sshleifer/tiny-gpt2","messages":[{"role":"user","content":"hi"}],"max_tokens":4}')" \
  || fail "the chat completion request failed"
echo "$body" | jq -e '.choices | length > 0' >/dev/null || fail "no choices in the answer"
ok "chat completion"

echo "== 8. absence of components that the core does not install"
if [ "$NS" != aims-test ]; then
  echo "NAMESPACE is $NS, so this is not a minimal core cluster, step 8 is skipped"
else
for ns in seaweedfs-instance keda opentelemetry-system; do
  kubectl get namespace "$ns" >/dev/null 2>&1 && fail "namespace $ns exists"
done
kubectl get crd -o name | grep -Eq 'keda\.sh$|opentelemetry\.io$|seaweed\.seaweedfs\.com$' \
  && fail "CRDs of an optional component exist"
# Discovery pods appear and finish all the time, so give them a moment.
for _ in $(seq 1 6); do
  bad="$(kubectl get pods --all-namespaces \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o name | wc -l)"
  [ "$bad" -eq 0 ] && break
  sleep 10
done
[ "$bad" -eq 0 ] || { kubectl get pods --all-namespaces \
  --field-selector=status.phase!=Running,status.phase!=Succeeded; \
  fail "$bad pods are not Running or Succeeded"; }
ok "no unexpected components"
fi

echo "== 9. clean up"
if [ "${KEEP:-0}" = 1 ]; then
  echo "KEEP=1, namespace $NS stays"
elif [ "$NS" = aims-test ]; then
  kubectl delete namespace "$NS" --wait=false >/dev/null
else
  # A namespace that another release owns stays, only the test object goes.
  kubectl delete aimservice aim-dummy --namespace "$NS" --wait=false >/dev/null
fi
echo "SMOKE TEST PASSED"
