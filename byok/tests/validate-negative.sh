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

# The profile format: extends, vars and notes.
run_validate() { # <profile file> [--var name=value]...
  local f="$1"; shift
  PATH="$tmp:$PATH" KUBECONFIG=/dev/null "$HERE/../bootstrap.sh" validate --profile "$f" "$@" 2>&1
}

expect_fail() { # <label> <pattern> <profile file> [--var ...]
  local label="$1" pattern="$2"; shift 2
  local out rc=0
  out="$(run_validate "$@")" || rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: $label passed" >&2; exit 1; }
  echo "$out" | grep -q "$pattern" \
    || { echo "FAIL: $label does not name the cause:" >&2; echo "$out" >&2; exit 1; }
  echo "ok: $label"
}

cat > "$tmp/base.yaml" <<'EOF'
name: base
packages:
  - name: gateway-api-crds
EOF

cat > "$tmp/no-base.yaml" <<'EOF'
name: no-base
extends: missing
packages: []
EOF
expect_fail "extends of a missing base" "does not exist" "$tmp/no-base.yaml"

cat > "$tmp/chain-base.yaml" <<'EOF'
name: chain-base
extends: base
packages: []
EOF
cat > "$tmp/chain.yaml" <<'EOF'
name: chain
extends: chain-base
packages: []
EOF
expect_fail "extends chain" "one level only" "$tmp/chain.yaml"

cat > "$tmp/empty-var.yaml" <<'EOF'
name: empty-var
vars:
  domain:
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${domain}
EOF
expect_fail "a required var without a value" "domain" "$tmp/empty-var.yaml"

cat > "$tmp/undeclared.yaml" <<'EOF'
name: undeclared
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${nowhere}
EOF
expect_fail "an undeclared variable in the text" "nowhere" "$tmp/undeclared.yaml"

expect_fail "--var for a name that the profile does not declare" "does not declare" \
  "$tmp/base.yaml" --var domain=example.com

# The happy path: extends, a var with a value, and the notes.
cat > "$tmp/child.yaml" <<'EOF'
name: child
extends: base
vars:
  domain:
  optional: ""
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${domain}
        extra: "${optional}"
notes: |
  URL: https://ui.${domain}
EOF
out="$(run_validate "$tmp/child.yaml" --var domain=example.com)" \
  || { echo "FAIL: the good profile did not validate:" >&2; echo "$out" >&2; exit 1; }
echo "ok: extends, vars and notes validate"
