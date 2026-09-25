#!/usr/bin/env bash
# Prints a markdown footprint report for the installed byok profile.
# Usage: footprint.sh [label]
set -euo pipefail

LABEL="${1:-idle}"
# The demo profile adds: envoy-gateway-system aiwb keycloak postgres
NAMESPACES="${NAMESPACES:-kyverno cert-manager kserve-system aim-system}"

echo "## Footprint: $LABEL"
echo
echo "- date: $(date -u +%Y-%m-%d)"
echo "- kubernetes: $(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
echo "- nodes: $(kubectl get nodes -o name | wc -l)"
echo

# A Job leaves its pods behind in Succeeded, and aim-catalog makes hundreds of
# them. Only a running pod holds resources.
echo "### Running pods and requests per namespace"
echo
echo "| namespace | pods | cpu requests | memory requests | cpu limits | memory limits |"
echo "|---|---|---|---|---|---|"
for ns in $NAMESPACES; do
  kubectl get pods --namespace "$ns" --field-selector=status.phase=Running -o json | jq -r --arg ns "$ns" '
    def milli: if . == null then 0
      else tostring as $s
      | if $s | endswith("m") then ($s[:-1] | tonumber)
        else ($s | tonumber) * 1000 end end;
    def mib: if . == null then 0
      else tostring as $s
      | (if   $s | endswith("Ki") then [$s[:-2], 1 / 1024]
         elif $s | endswith("Mi") then [$s[:-2], 1]
         elif $s | endswith("Gi") then [$s[:-2], 1024]
         elif $s | endswith("Ti") then [$s[:-2], 1048576]
         elif $s | endswith("k")  then [$s[:-1], 1000 / 1048576]
         elif $s | endswith("M")  then [$s[:-1], 1000000 / 1048576]
         elif $s | endswith("G")  then [$s[:-1], 1000000000 / 1048576]
         elif $s | endswith("T")  then [$s[:-1], 1000000000000 / 1048576]
         else [$s, 1 / 1048576] end) as [$number, $factor]
      | ($number | tonumber) * $factor end;
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
