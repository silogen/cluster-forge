#!/usr/bin/env bash
# Compares the byok package pins with root/values.yaml. Needs no cluster.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
VALUES="$ROOT/root/values.yaml"
rc=0

report() { echo "drift: $*" >&2; rc=1; }

dep_field() { # <package> <dependency> <field>
  PKG_DEP="$2" yq -r ".dependencies[] | select(.name == strenv(PKG_DEP)) | .$3" \
    "$HERE/../packages/$1/Chart.yaml"
}

# sources/cert-manager-config has no ArgoCD app, so the selfsigned-tls package
# has no row here.
# In-repo charts: the byok dependency must point at the same sources/ directory
# that the ArgoCD app uses. There is no seaweedfs-crds row: that ArgoCD app is
# deprecated and the seaweedfs-operator chart ships the CRDs itself.
# package:dependency:app
for row in \
  "cert-manager:cert-manager:cert-manager" \
  "kserve:kserve:kserve" \
  "kserve-crds:kserve-crd:kserve-crds" \
  "seaweedfs-operator:seaweedfs-operator:seaweedfs-operator" \
  "kyverno:kyverno:kyverno" \
  "kyverno-policies-storage-local-path:kyverno-policies-storage-local-path:kyverno-policies-storage-local-path" \
  "envoy-gateway:gateway-helm:envoy-gateway" \
  "envoy-gateway-config:envoy-gateway-config:envoy-gateway-config" \
  "keycloak:keycloak-old:keycloak"
do
  IFS=: read -r pkg dep app <<<"$row"
  want="$(APP="$app" yq -r '.apps[strenv(APP)].path' "$VALUES")"
  got="$(dep_field "$pkg" "$dep" repository)"
  got="${got#file://../../../sources/}"
  [ "$got" = "$want" ] || report "package $pkg dependency $dep uses sources/$got, root/values.yaml uses $want"
done

# The Gateway API CRDs come from the crds subchart of the vendored
# envoy-gateway chart, so compare the parent path.
want="$(APP=envoy-gateway yq -r '.apps[strenv(APP)].path' "$VALUES")/charts/crds"
got="$(dep_field gateway-api-crds crds repository)"
got="${got#file://../../../sources/}"
[ "$got" = "$want" ] || report "package gateway-api-crds uses sources/$got, root/values.yaml uses $want"

# OCI charts: the byok dependency version must match the ArgoCD repoVersion.
# package:dependency:app
for row in \
  "aim-engine:aim-engine-chart:aim-engine" \
  "aim-engine-crds:aim-engine-crds-chart:aim-engine-crds" \
  "aiwb:aiwb-chart:aiwb"
do
  IFS=: read -r pkg dep app <<<"$row"
  want="$(APP="$app" yq -r '.apps[strenv(APP)].repoVersion' "$VALUES")"
  got="$(dep_field "$pkg" "$dep" version)"
  [ "$got" = "$want" ] || report "package $pkg dependency $dep is pinned to $got, root/values.yaml uses $want"
done

# The opentelemetry-crds chart holds a render of the collector CRD from the
# operator chart. Render it again and compare.
otel_src="$ROOT/sources/opentelemetry-operator/$(APP=opentelemetry-operator yq -r '.apps[strenv(APP)].path' "$VALUES" | sed 's|^opentelemetry-operator/||')"
otel_copy="$ROOT/sources/opentelemetry-operator-crds/0.93.1/crds/crd-opentelemetrycollector.yaml"
if [ -d "$otel_src" ]; then
  tmp="$(mktemp)"
  helm template otel "$otel_src" \
    --set admissionWebhooks.create=false --set admissionWebhooks.certManager.enabled=false \
    --set crds.create=true -s templates/admission-webhooks/operator-webhook.yaml \
    | yq 'select(.metadata.name == "opentelemetrycollectors.opentelemetry.io")' > "$tmp"
  diff -q "$tmp" "$otel_copy" >/dev/null \
    || report "the CRD copy in sources/opentelemetry-operator-crds differs from the render of $otel_src"
  rm -f "$tmp"
else
  report "no operator chart at $otel_src"
fi

[ "$rc" -eq 0 ] && echo "no version drift"
exit "$rc"
