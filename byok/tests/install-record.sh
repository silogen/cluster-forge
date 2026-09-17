#!/usr/bin/env bash
# Proves what `bootstrap.sh remove --profile` takes off a cluster. Needs no
# cluster: helm and kubectl are stubbed and keep their state in files, so the
# test can read back the order of the uninstalls and the record patches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/helm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) echo "v3.19.0";;
  status)  grep -qx "$2" "$STUB_STATE/installed" || exit 1;;
  uninstall)
    echo "$2" >> "$STUB_STATE/uninstalled"
    grep -vx "$2" "$STUB_STATE/installed" > "$STUB_STATE/installed.new" || true
    mv "$STUB_STATE/installed.new" "$STUB_STATE/installed"
    ;;
  "get") ;;  # get manifest: no CRDs
  *) ;;
esac
exit 0
EOF

cat > "$tmp/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth can-i") exit 0;;
  "get configmap")
    case "$*" in
      *-o\ json*) cat "$STUB_STATE/record.json";;
      *) [ -s "$STUB_STATE/record.json" ];;
    esac
    ;;
  "patch configmap")
    # The merge patch is the last argument of -p.
    for a in "$@"; do [ "$prev" = "-p" ] && echo "$a" >> "$STUB_STATE/patches"; prev="$a"; done
    ;;
  "delete "*) echo "delete $*" >> "$STUB_STATE/deletes";;
esac
exit 0
EOF
chmod +x "$tmp/helm" "$tmp/kubectl"

export STUB_STATE="$tmp"
export PATH="$tmp:$PATH"
export KUBECONFIG=/dev/null

base_packages="kyverno kyverno-policies-storage-local-path cert-manager kserve-crds kserve gateway-api-crds aim-engine-crds aim-engine aim-catalog"
demo_only="envoy-gateway selfsigned-tls envoy-gateway-config opentelemetry-crds aiwb-demo-secrets postgres dex aiwb"

reset_state() { # <record json> [installed packages]
  : > "$tmp/uninstalled"
  : > "$tmp/patches"
  : > "$tmp/deletes"
  printf '%s' "${2-$base_packages $demo_only}" | tr ' ' '\n' | grep -v '^$' > "$tmp/installed" || true
  printf '%s' "$1" > "$tmp/record.json"
}

record_of() { # <profile>... -> a ConfigMap json whose data holds those profiles
  local p entry data='{}'
  for p in "$@"; do
    entry="$(yq -r '.name' "$HERE/../profiles/$p.yaml" >/dev/null && \
      PROFILE="$p" jq -nc --argjson pkgs "$(profile_packages_json "$p")" \
        '{ref: "test", installed: "2026-09-15T00:00:00Z", vars: {}, packages: $pkgs}')"
    data="$(jq -c --arg k "$p" --arg v "$entry" '. + {($k): $v}' <<<"$data")"
  done
  jq -nc --argjson data "$data" '{data: $data}'
}

profile_packages_json() { # <profile> -> the package names, extends resolved
  local p="$1"
  if [ "$p" = demo ]; then
    printf '%s %s' "$base_packages" "$demo_only" | tr ' ' '\n' | jq -Rc -s 'split("\n") | map(select(length > 0))'
  else
    printf '%s' "$base_packages" | tr ' ' '\n' | jq -Rc -s 'split("\n") | map(select(length > 0))'
  fi
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Both profiles recorded: the shared base stays.
reset_state "$(record_of demo default)"
"$HERE/../bootstrap.sh" remove --profile "$HERE/../profiles/demo.yaml" --purge >/dev/null

for pkg in $demo_only; do
  grep -qx "$pkg" "$tmp/uninstalled" || fail "$pkg of demo was not removed"
done
for pkg in $base_packages; do
  grep -qx "$pkg" "$tmp/uninstalled" && fail "$pkg is still needed by default, but it was removed"
done
[ "$(head -n1 "$tmp/uninstalled")" = aiwb ] \
  || fail "the removal did not start from the last package of the profile, it started from $(head -n1 "$tmp/uninstalled")"
grep -q '"demo":null' "$tmp/patches" || fail "the install record still holds demo"
echo "ok: a package that another recorded profile holds stays"

# 2. Only demo recorded: the base goes too, in reverse install order.
reset_state "$(record_of demo)"
"$HERE/../bootstrap.sh" remove --profile "$HERE/../profiles/demo.yaml" --purge >/dev/null

for pkg in $base_packages $demo_only; do
  grep -qx "$pkg" "$tmp/uninstalled" || fail "$pkg was not removed"
done
[ "$(tail -n1 "$tmp/uninstalled")" = kyverno ] \
  || fail "the removal did not end at the first package of the profile"
grep -q 'delete namespace' "$tmp/deletes" || fail "--purge did not delete a namespace"
echo "ok: the whole profile goes when no other profile holds its packages"

# 3. Nothing recorded: the profile file gives the package list.
reset_state '{}' "$base_packages"
"$HERE/../bootstrap.sh" remove --profile "$HERE/../profiles/default-cpu.yaml" >/dev/null
for pkg in $base_packages; do
  grep -qx "$pkg" "$tmp/uninstalled" || fail "$pkg was not removed without an install record"
done
grep -q 'delete namespace' "$tmp/deletes" && fail "a remove without --purge deleted a namespace"
echo "ok: without an install record the profile file gives the packages"

# 4. A package that is not installed is skipped, not an error.
reset_state "$(record_of default-cpu)" ""

"$HERE/../bootstrap.sh" remove --profile "$HERE/../profiles/default-cpu.yaml" >/dev/null
[ ! -s "$tmp/uninstalled" ] || fail "an uninstall ran for a package that is not installed"
echo "ok: a package that is not installed is skipped"

# 5. An installed package outside the record still guards its capability.
reset_state '{}'
out="$("$HERE/../bootstrap.sh" remove --profile "$HERE/../profiles/default-cpu.yaml" 2>&1)" \
  && fail "the base profile went away under an installed aiwb"
grep -q 'aiwb is installed and needs' <<<"$out" \
  || fail "the message does not name the package that still needs the capability: $out"
echo "ok: an installed package outside the record keeps its provider"
