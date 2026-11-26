#!/usr/bin/env bash
# Enable the OpenBao dashboard admin in the cluster-values repository.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "${script_dir}/.." && pwd)

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Run this script from the root of the cluster-values repository." >&2
  exit 1
fi

dest=$(git rev-parse --show-toplevel)
if [[ "$(pwd -P)" != "${dest}" ]]; then
  echo "Run this script from the repository root: ${dest}" >&2
  exit 1
fi

blueprint_repo=$(git -C "${src}" rev-parse --show-toplevel)
if [[ "${blueprint_repo}" == "${dest}" ]]; then
  echo "Run this script from the root of the cluster-values repository." >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is not available. Install mikefarah yq, then start the script again." >&2
  exit 1
fi

yq_version=$(yq --version 2>&1 || true)
if [[ "${yq_version}" != *mikefarah* ]]; then
  echo "yq is not mikefarah yq. Install mikefarah yq, then start the script again." >&2
  exit 1
fi

chart_templates="extra-apps/semantic-router/chart/templates"
values_file="extra-apps/semantic-router/values.yaml"
externalsecret_name="dashboard-admin-externalsecret.yaml"

if [[ ! -d "${chart_templates}" || ! -f "${values_file}" ]]; then
  echo "The semantic-router chart is not in this repository. Run setup.sh first." >&2
  exit 1
fi

echo "Blueprint: ${src}"
echo "Destination: ${dest}"

cp "${src}/manifests/${externalsecret_name}" "${chart_templates}/${externalsecret_name}"

# The blueprint ships jwtSecret and extraEnv as comments. Remove the comment
# marker on that block only. A second run leaves an already active block as it is.
tmp=$(mktemp)
awk '
  {
    line = $0
    if (line ~ /^  # jwtSecret:$/ ||
        line ~ /^  #   existingSecret: semantic-router-dashboard-admin$/ ||
        line ~ /^  #   existingSecretKey: jwt-secret$/ ||
        line ~ /^  # extraEnv:$/ ||
        line ~ /^  #   - name: DASHBOARD_ADMIN_(EMAIL|NAME|PASSWORD)$/ ||
        line ~ /^  #     valueFrom:$/ ||
        line ~ /^  #       secretKeyRef:$/ ||
        line ~ /^  #         name: semantic-router-dashboard-admin$/ ||
        line ~ /^  #         key: (email|name|password)$/) {
      sub(/^  # /, "  ", line)
    }
    print line
  }
' "${values_file}" > "${tmp}"
mv "${tmp}" "${values_file}"

jwt_secret=$(yq eval '.dashboard.jwtSecret.existingSecret' "${values_file}")
jwt_key=$(yq eval '.dashboard.jwtSecret.existingSecretKey' "${values_file}")
if [[ "${jwt_secret}" != "semantic-router-dashboard-admin" || "${jwt_key}" != "jwt-secret" ]]; then
  echo "dashboard.jwtSecret is not set in ${values_file}." >&2
  exit 1
fi

while read -r env_name secret_key; do
  got_name=$(yq eval ".dashboard.extraEnv[] | select(.name == \"${env_name}\") | .valueFrom.secretKeyRef.name" "${values_file}")
  got_key=$(yq eval ".dashboard.extraEnv[] | select(.name == \"${env_name}\") | .valueFrom.secretKeyRef.key" "${values_file}")
  if [[ "${got_name}" != "semantic-router-dashboard-admin" || "${got_key}" != "${secret_key}" ]]; then
    echo "dashboard.extraEnv ${env_name} is not set in ${values_file}." >&2
    exit 1
  fi
done <<'EOF'
DASHBOARD_ADMIN_EMAIL email
DASHBOARD_ADMIN_NAME name
DASHBOARD_ADMIN_PASSWORD password
EOF

git add \
  "${chart_templates}/${externalsecret_name}" \
  "${values_file}"
if ! git diff --cached --quiet; then
  git commit -m "feat: Enable semantic-router dashboard admin"
else
  echo "No file changes to commit."
fi

# Push with GITEA_USERNAME and GITEA_PASSWORD when both are set. Otherwise git
# prompts. The helper reads the variables from its environment, so the password
# is not on the command line or in the repository.
push_overlay() {
  if [[ -n "${GITEA_USERNAME:-}" && -n "${GITEA_PASSWORD:-}" ]]; then
    git -c credential.helper= \
      -c 'credential.helper=!f() { test "$1" = get || exit 0; echo "username=$GITEA_USERNAME"; echo "password=$GITEA_PASSWORD"; }; f' \
      push
  else
    git push
  fi
}
push_overlay

echo "Sign in at https://sr-dashboard.<domain> after the Application is Synced."
echo "Email: admin@<domain>. Display name: admin."
echo "Read the password:"
echo "kubectl -n semantic-router get secret semantic-router-dashboard-admin -o jsonpath='{.data.password}' | base64 -d; echo"
