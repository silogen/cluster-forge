#!/usr/bin/env bash
# Prints a markdown footprint report for the installed byok profile.
# Usage: footprint.sh [label]
set -euo pipefail

LABEL="${1:-idle}"
NAMESPACES="${NAMESPACES:-kyverno cert-manager kserve-system aim-system}"

echo "## Footprint: $LABEL"
echo
echo "- date: $(date -u +%Y-%m-%d)"
echo "- kubernetes: $(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
echo "- nodes: $(kubectl get nodes -o name | wc -l)"
echo

echo "### Pods and requests per namespace"
echo
echo "| namespace | pods | cpu requests | memory requests | cpu limits | memory limits |"
echo "|---|---|---|---|---|---|"
for ns in $NAMESPACES; do
  kubectl get pods --namespace "$ns" -o json | jq -r --arg ns "$ns" '
    def milli: if . == null then 0
      elif endswith("m") then (.[:-1] | tonumber)
      else ((. | tonumber) * 1000) end;
    def mib: if . == null then 0
      elif endswith("Ki") then (.[:-2] | tonumber) / 1024
      elif endswith("Mi") then (.[:-2] | tonumber)
      elif endswith("Gi") then (.[:-2] | tonumber) * 1024
      else (. | tonumber) / 1048576 end;
    [.items[].spec.containers[].resources] as $r
    | "| \($ns) | \(.items | length)"
      + " | \([$r[].requests.cpu | milli] | add // 0)m"
      + " | \([$r[].requests.memory | mib] | add // 0 | floor)Mi"
      + " | \([$r[].limits.cpu | milli] | add // 0)m"
      + " | \([$r[].limits.memory | mib] | add // 0 | floor)Mi |"'
done
echo

echo "### Live usage"
echo
if kubectl top pods --all-namespaces >/dev/null 2>&1; then
  echo '```'
  for ns in $NAMESPACES; do kubectl top pods --namespace "$ns" --no-headers 2>/dev/null | sed "s|^|$ns/|"; done
  echo '```'
else
  echo "metrics-server is not available, no live usage"
fi
echo

echo "### Persistent volume claims"
echo
echo '```'
kubectl get pvc --all-namespaces --no-headers 2>/dev/null || echo "none"
echo '```'
echo

echo "### Images on the node"
echo
echo '```'
if command -v crictl >/dev/null 2>&1; then
  crictl images --output json 2>/dev/null \
    | jq -r '[.images[].size | tonumber] | add / 1073741824 | "total image size: \(. * 100 | round / 100) GiB"'
elif command -v k0s >/dev/null 2>&1; then
  echo "images: $(sudo k0s ctr images ls -q 2>/dev/null | wc -l)"
  sudo du -sh /var/lib/k0s/containerd 2>/dev/null
else
  echo "run this on the node to get the image size"
fi
echo '```'
