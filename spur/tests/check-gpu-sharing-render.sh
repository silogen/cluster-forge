#!/usr/bin/env bash
# Renders the GPU operator packages with the values of the gpu-sharing and
# default profiles, and checks the DRA configuration of GPU sharing. Needs helm
# and yq, no cluster.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$HERE/../packages"
VALUES="$HERE/../../root/values.yaml"
rc=0
fail() { echo "gpu-sharing render: $*" >&2; rc=1; }

for p in amd-gpu-operator amd-gpu-operator-config; do
  helm dependency build "$PKG/$p" >/dev/null
done

# The operator chart makes its DeviceClass only when the API server has the
# resource.k8s.io/v1 API, so give helm that API as a cluster would.
# Each package gets the values that its entry in the profile gives.
render() { # <profile>
  for p in amd-gpu-operator amd-gpu-operator-config; do
    PKG_NAME="$p" yq '.packages[] | select(.name == strenv(PKG_NAME)) | .values // {}' \
      "$HERE/../profiles/$1.yaml" >"$vals"
    helm template spur "$PKG/$p" -n kube-amd-gpu --api-versions resource.k8s.io/v1 -f "$vals"
    echo ---
  done
}
on="$(mktemp)"
off="$(mktemp)"
vals="$(mktemp)"
trap 'rm -f "$on" "$off" "$vals"' EXIT
render gpu-sharing >"$on"
render default >"$off"

q() { yq ea -r "$2" "$1"; }
expect() { # <file> <query> <want> <message>
  got="$(q "$1" "$2")"
  [ "$got" = "$3" ] || fail "$4: got '$got', want '$3'"
}

dc='select(.kind == "DeviceClass" and .metadata.name == "gpu.amd.com")'
cfg() { echo "select(.kind == \"DeviceConfig\" and .metadata.name == \"$1\")"; }

expect "$on" "[$dc] | length" 1 "one DeviceClass gpu.amd.com"
expect "$on" "$dc | .spec.extendedResourceName" amd.com/gpu "extendedResourceName"
expect "$on" "$dc | .spec.selectors[0].cel.expression" "device.driver == 'gpu.amd.com'" "DeviceClass selector"
expect "$on" "$(cfg gpu-operator-dra) | .spec.draDriver.image" docker.io/rocm/k8s-gpu-dra-driver:v1.0.1 "pinned DRA driver image"
expect "$on" "$(cfg gpu-operator-dra) | .spec.devicePlugin.enableDevicePlugin" false "no device plugin next to DRA"
expect "$on" "$(cfg gpu-operator-dra) | .spec.selector[\"spur.amd.com/gpu-sharing\"]" true "DRA on shared nodes"
expect "$on" "$(cfg gpu-operator) | .spec.draDriver.enable" false "no DRA next to the device plugin"
expect "$on" "$(cfg gpu-operator-dra) | .spec.metricsExporter.podResourceAPISocketPath" /var/lib/k0s/kubelet/pod-resources "k0s pod-resources path"
expect "$on" "$(cfg gpu-operator) | .spec.selector[\"spur.amd.com/gpu-sharing\"]" false "device plugin off shared nodes"

# Without GPU sharing nothing changes, and no chart makes the class.
expect "$off" "[$dc] | length" 0 "no DeviceClass without GPU sharing"
expect "$off" "[$(cfg gpu-operator-dra)] | length" 0 "no DRA DeviceConfig without GPU sharing"
expect "$off" "$(cfg gpu-operator) | .spec.selector | has(\"spur.amd.com/gpu-sharing\")" false "device plugin selector unchanged"

# The ArgoCD path must keep the operator chart away from the class too.
expect "$VALUES" '.apps.amd-gpu-operator.valuesObject.draDriver.deviceClass.create' false "root/values.yaml deviceClass.create"

exit "$rc"
