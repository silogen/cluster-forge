#!/usr/bin/env bash
# Installs the optional seaweedfs packages on top of default-cpu with the
# test-s3 profile, re-runs the install, then removes test-s3 with the data and
# proves that nothing of seaweedfs stays and that the base still works.
# Needs a cluster, helm and kubectl, and the spur-aims binary.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYOK="$HERE/.."
SPUR_AIMS="${SPUR_AIMS:-$BYOK/spur-aims/spur-aims}"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

[ -x "$SPUR_AIMS" ] || fail "no binary at $SPUR_AIMS, run make -C $BYOK/spur-aims assets build"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== 1. install default-cpu, then the seaweedfs packages on top of it"
"$SPUR_AIMS" install default-cpu
"$SPUR_AIMS" install test-s3

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
"$SPUR_AIMS" install test-s3
release_state > "$tmp/after.txt"
diff "$tmp/before.txt" "$tmp/after.txt" || fail "the rendered manifests changed on the second install"
ok "no change on the second install"

echo "== 4. remove test-s3 with the data"
"$SPUR_AIMS" uninstall test-s3 --yes

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
