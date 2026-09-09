#!/usr/bin/env bash
# Proves that validation stops a profile with a missing capability.
# Needs no cluster: kubectl is stubbed, so every capability probe fails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/kubectl" <<'EOF'
#!/bin/sh
# cluster-admin yes, every capability probe no
[ "$1" = auth ] && exit 0
exit 1
EOF
chmod +x "$tmp/kubectl"

cat > "$tmp/bad-profile.yaml" <<'EOF'
name: bad
packages:
  - name: gateway-api-crds
  - name: aim-engine-crds
  - name: aim-engine
EOF

out="$(PATH="$tmp:$PATH" KUBECONFIG=/dev/null \
  "$HERE/../bootstrap.sh" validate --profile "$tmp/bad-profile.yaml" 2>&1)" && rc=0 || rc=$?

[ "$rc" -ne 0 ] || { echo "FAIL: validation passed a profile with a missing capability" >&2; exit 1; }
echo "$out" | grep -q 'serving.kserve' \
  || { echo "FAIL: the message does not name the missing capability:" >&2; echo "$out" >&2; exit 1; }
echo "$out" | grep -q 'kserve' \
  || { echo "FAIL: the message does not name a provider package" >&2; exit 1; }
echo "ok: validation stops on a missing capability"
