#!/bin/bash

# Allow execution from anywhere
cd "$(dirname "$0")"

CERT_DIR="${CERT_DIR:-"/usr/local/share/ca-certificates"}"

clusters="$(kind get clusters)"
if [[ "$clusters" == "" ]]; then
  echo "No kind clusters found" >&2
  exit 1
fi

while IFS= read -r cluster; do
  containers="$(kind get nodes --name="$cluster" 2>/dev/null)"
  if [[ "$containers" == "" ]]; then
    echo "No kind nodes found for cluster \"$cluster\"" >&2
    continue
  fi

  while IFS= read -r container; do
    echo "Copying AMD_ROOT.crt to ${container}:${CERT_DIR}"
    docker cp certs/AMD_ROOT.crt "${container}:${CERT_DIR}"
    echo "Copying AMD_ISSUER.crt to ${container}:${CERT_DIR}"
    docker cp certs/AMD_ISSUER.crt "${container}:${CERT_DIR}"

    echo "Updating CA certificates in ${container}..."
    docker exec "$container" update-ca-certificates

    echo "Restarting containerd"
    docker exec "$container" systemctl restart containerd
  done <<< "$containers"
done <<< "$clusters"