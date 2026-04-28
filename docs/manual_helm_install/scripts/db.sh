#!/bin/bash

# DEPRECATED — pluggable database configuration is now handled by install_base.sh
#
# Previously this script patched the cluster after install_base.sh had already
# deployed the in-cluster CNPG cluster: it deleted the Cluster resources, rewrote
# the database secrets, and used kubectl set env / kubectl patch to redirect
# AIWB and Keycloak deployments at an external PostgreSQL.
#
# Now install_base.sh accepts PLUGGABLE_DB=true and passes the connection
# parameters directly to the helm template invocations. No post-install patching
# is needed; AIWB and Keycloak are deployed against the external database from
# the start.
#
# Usage (from components/db.md):
#   PLUGGABLE_DB=true \
#     POSTGRES_HOST=your-db-host POSTGRES_PORT=5432 \
#     AIWB_DB_NAME=aiwb AIWB_DB_USER=aiwb_user AIWB_DB_PASSWORD=... \
#     KEYCLOAK_DB_NAME=keycloak KEYCLOAK_DB_USER=keycloak KEYCLOAK_DB_PASSWORD=... \
#     ./install_base.sh <DOMAIN>
#
# This file can be deleted once all consumers have migrated.

set -euo pipefail

cat <<EOF >&2
db.sh is deprecated. Pluggable database configuration is now done via
install_base.sh PLUGGABLE_DB=true. See components/db.md for instructions.

If you reached this script from old documentation, run instead:

  PLUGGABLE_DB=true \\
    POSTGRES_HOST=\${POSTGRES_HOST:-host.docker.internal} \\
    POSTGRES_PORT=\${POSTGRES_PORT:-5432} \\
    AIWB_DB_NAME=\${AIWB_DB_NAME:-aiwb} \\
    AIWB_DB_USER=\${AIWB_DB_USER:-aiwb_user} \\
    AIWB_DB_PASSWORD=\${AIWB_DB_PASSWORD:-...} \\
    KEYCLOAK_DB_NAME=\${KEYCLOAK_DB_NAME:-keycloak} \\
    KEYCLOAK_DB_USER=\${KEYCLOAK_DB_USER:-keycloak} \\
    KEYCLOAK_DB_PASSWORD=\${KEYCLOAK_DB_PASSWORD:-...} \\
    ./install_base.sh <DOMAIN>
EOF
exit 1
