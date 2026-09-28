#!/usr/bin/env bash
# Print a Dex token for the model routes of a demo cluster, and a curl
# example. It uses the password grant of Dex for devuser@<domain>. curl -k,
# because the demo certificate is self-signed.
set -euo pipefail
domain="$(kubectl get gateway https -n envoy-gateway-system \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}')"
domain="${domain#\*.}"
dex() { kubectl get secret dex-credentials -n dex -o jsonpath="{.data.$1}" | base64 -d; }
token="$(curl -skf "https://auth.$domain/token" -d grant_type=password -d client_id=aiwb \
  -d "client_secret=$(dex client-secret)" -d "username=devuser@$domain" \
  -d "password=$(dex password)" -d 'scope=openid email' | jq -r .access_token)"
route="$(kubectl get httproute -A -l aim.eai.amd.com/service -o json | jq -r \
  '.items[0] // empty | "\(.metadata.namespace)/\(.metadata.labels["airm.silogen.ai/workload-id"])"')"
echo "export TOKEN=$token"
echo
echo "# The token is valid for 7 days, or until the Dex Pod restarts."
echo "curl -sk -H \"Authorization: Bearer \$TOKEN\" \\"
echo "  https://workloads.$domain/${route:-<namespace>/<workload-id>}/v1/models"
