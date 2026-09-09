#!/usr/bin/env bash
# Installs the optional seaweedfs package on top of the profile, re-runs the
# install, then removes seaweedfs with --purge and proves that nothing stays.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYOK="$HERE/.."
PROFILE="${PROFILE:-$BYOK/profiles/scalable-inference.yaml}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq '.packages += [{"name": "seaweedfs-operator"}, {"name": "seaweedfs"}]' "$PROFILE" > "$tmp/with-seaweedfs.yaml"

echo "== 1. install the profile with seaweedfs"
"$BYOK/bootstrap.sh" install --profile "$tmp/with-seaweedfs.yaml"

echo "== 2. seaweedfs is up"
bash -c "$(yq -r '.["storage.s3"].probe' "$BYOK/capabilities.yaml")" \
  || fail "the storage.s3 probe failed"
kubectl wait --for=condition=Ready pod --all --namespace seaweedfs-instance --timeout=10m >/dev/null \
  || fail "seaweedfs pods are not ready"
ok "seaweedfs is ready"

echo "== 3. the install is idempotent"
# helm upgrade makes a new revision on every run, so compare the rendered
# manifests and the release set, not the revision numbers.
release_state() {
  helm list --all-namespaces -o json | jq -r '.[] | "\(.name) \(.namespace) \(.chart)"' | sort | while read -r name ns chart; do
    echo "== $name $ns $chart"
    helm get manifest "$name" --namespace "$ns"
  done
}
release_state > "$tmp/before.txt"
"$BYOK/bootstrap.sh" install --profile "$tmp/with-seaweedfs.yaml"
release_state > "$tmp/after.txt"
diff "$tmp/before.txt" "$tmp/after.txt" || fail "the rendered manifests changed on the second install"
ok "no change on the second install"

echo "== 4. remove seaweedfs"
"$BYOK/bootstrap.sh" remove seaweedfs --purge
"$BYOK/bootstrap.sh" remove seaweedfs-operator --purge

echo "== 5. nothing of seaweedfs stays"
helm status seaweedfs --namespace seaweedfs-instance >/dev/null 2>&1 \
  && fail "the helm release still exists"
helm status seaweedfs-operator --namespace seaweedfs-operator >/dev/null 2>&1 \
  && fail "the operator helm release still exists"
kubectl get namespace seaweedfs-instance >/dev/null 2>&1 && fail "the namespace still exists"
kubectl get crd -o name | grep -q 'seaweed\.seaweedfs\.com$' && fail "seaweedfs CRDs still exist"
ok "seaweedfs is gone"

echo "== 6. the core still works"
"$HERE/smoke.sh"
echo "OPTIONAL PACKAGE CYCLE PASSED"
