#!/bin/bash

# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

#####################################################################################
echo ""
echo "Run configure script block..."
echo ""

# --- Configuration Variables ---
# Get values from bloom configmap mounted as env

# NOTE: ORG_NAME is hardcoded to demo because gpu operator metrics has same org name hardcoded there
# Otherwise the following line can be uncommented to consider the real org name from domain config
# ORG_NAME=$(echo $NEW_DOMAIN_NAME | awk -F '.' '{ print $2 }')
ORG_NAME="demo"
ORG_DOMAINS="[\"${NEW_DOMAIN_NAME}\"]"
CLUSTER_WORKLOADS_BASE_URL="https://workspaces.${NEW_DOMAIN_NAME}/"
CLUSTER_KUBE_API_URL="https://k8s.${NEW_DOMAIN_NAME}"
USER_EMAIL="devuser@${NEW_DOMAIN_NAME}"
PROJECT_NAME="demo"
PROJECT_DESCRIPTION="demo"
CLUSTER_NAME="demo-cluster"
TIMEOUT=300
SLEEP_INTERVAL=5

# --- Input Validation ---
echo "Validating environment variables..."
echo "KEYCLOAK_CLIENT_ID: ${KEYCLOAK_CLIENT_ID}"
echo "NEW_DOMAIN_NAME: ${NEW_DOMAIN_NAME}"
echo "AIRM_API_URL: ${AIRM_API_URL}"

function check_env_variable() {
  if [ -z "${!1}" ]; then
    echo "ERROR: $1 environment variable is not set."
    exit 1
  fi
}

function check_success() {
    if [ "$1" -ne 0 ]; then
        echo "ERROR: $2"
        exit 1
    fi
}

check_env_variable "AIRM_API_URL"
check_env_variable "KEYCLOAK_URL"
check_env_variable "KEYCLOAK_REALM"
check_env_variable "KEYCLOAK_CLIENT_SECRET"
check_env_variable "KEYCLOAK_CLIENT_ID"
check_env_variable "KEYCLOAK_ADMIN_CLIENT_ID"
check_env_variable "KEYCLOAK_ADMIN_CLIENT_SECRET"

function refresh_token() {
    echo "running from 0.3.1"
    echo "KEYCLOAK_CLIENT_ID $KEYCLOAK_CLIENT_ID"
    echo "USER_EMAIL: $USER_EMAIL"
    echo "KEYCLOAK_URL: $KEYCLOAK_URL"
    echo "KEYCLOAK_REALM: $KEYCLOAK_REALM"
    jq --version

    set -d

    TOKEN=$(curl -s -d "client_id=${KEYCLOAK_CLIENT_ID}" -d "username=${USER_EMAIL}" -d 'password=password' -d 'grant_type=password' -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" | jq -r '.access_token')
    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo "ERROR: Failed to obtain access token from Keycloak."
        exit 1
    fi

    set +d
}

function create_org() {
    # Try to get ORG_ID by name
    ORG_ID=$(curl -s -X GET "${AIRM_API_URL}/v1/organizations" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' | jq -r --arg name "$ORG_NAME" '.organizations[] | select(.name==$name) | .id')

    # If not found, create the org and fetch the ID again
    if [ -z "$ORG_ID" ] || [ "$ORG_ID" == "null" ]; then
        ORG_RESP=$(curl -s -o /dev/null -X POST -w "%{http_code}" "${AIRM_API_URL}/v1/organizations" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "{ \"name\": \"$ORG_NAME\", \"domains\": $ORG_DOMAINS }")
        echo "$ORG_RESP"
        check_success "$([[ "$ORG_RESP" == "200" || "$ORG_RESP" == "201" ]] && echo 0 || echo 1)" "Failed to create organization"

        ORG_ID=$(curl -s -X GET "${AIRM_API_URL}/v1/organizations" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' | jq -r --arg name "$ORG_NAME" '.organizations[] | select(.name==$name) | .id')
    fi

    if [ -z "$ORG_ID" ] || [ "$ORG_ID" == "null" ]; then
        echo "ERROR: Failed to create or retrieve organization ID."
        exit 1
    else
        echo "ORG_ID=${ORG_ID}"
    fi
}

function add_user_to_org() {
    # Check if user exists in org
    USER_EXISTS=$(curl -s -X GET "${AIRM_API_URL}/v1/users" -H 'accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' | jq -r --arg email "$USER_EMAIL" '.data? // [] | .[] | select(.email==$email) | .email')
    # Add user to org if they don't exist
    if [ -z "$USER_EXISTS" ] || [ "$USER_EXISTS" == "null" ]; then
        echo "$USER_EXISTS"
        echo "User '$USER_EMAIL' not found in organization. Adding..."
        ADD_USER_RESP=$(curl -w "%{http_code}" -X 'POST' "${AIRM_API_URL}/v1/organizations/${ORG_ID}/users" -H 'accept: application/json' -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{ "email": "'"$USER_EMAIL"'", "roles": ["Platform Administrator"]}')
        echo "$ADD_USER_RESP"
        check_success "$([[ "$ADD_USER_RESP" == "200" || "$ADD_USER_RESP" == "201" || "$ADD_USER_RESP" == "null201" ]] && echo 0 || echo 1)" "Failed to add user to organization"
    else
        echo "User '$USER_EMAIL' already exists in organization."
    fi
}

function create_project() {
    PROJECT_ID=$(curl -s -X GET "${AIRM_API_URL}/v1/projects" -H 'accept: application/json' -H "Authorization: Bearer ${TOKEN}" | jq -r '.projects[] | select(.name=="'$PROJECT_NAME'") | .id')

    for (( i=0; i<=TIMEOUT; i+=SLEEP_INTERVAL )); do
        CLUSTER_STATUS=$(curl -s -X GET "${AIRM_API_URL}/v1/clusters/$CLUSTER_ID" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' | jq -r '.status')

        if [ "$CLUSTER_STATUS" == "healthy" ]; then
        echo "Cluster is healthy!"
        break # Exit the loop if the cluster is healthy
        fi
        echo "Cluster status: $CLUSTER_STATUS.  Waiting $SLEEP_INTERVAL seconds... ($i/$TIMEOUT seconds elapsed)"
        sleep $SLEEP_INTERVAL
    done

    if [ "$CLUSTER_STATUS" != "healthy" ]; then
        echo "ERROR: Cluster did not become healthy within $TIMEOUT seconds."
        exit 1
    fi

    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" == "null" ]; then
        echo "Projects '$PROJECT_NAME' not found. Creating..."
        PROJECT_ID=$(curl -X 'POST' \
        "${AIRM_API_URL}/v1/projects" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{
            "name": "'"$PROJECT_NAME"'",
            "description": "'"$PROJECT_DESCRIPTION"'",
            "cluster_id": "'"$CLUSTER_ID"'",
            "quota": {
            "cpu_milli_cores": 0,
            "memory_bytes": 0,
            "ephemeral_storage_bytes": 0,
            "gpu_count": 0
            }
        }' | jq -r '.id')
        echo "$PROJECT_ID"
        check_success "$([[ "$PROJECT_ID" != "null" ]] && echo 0 || echo 1)" "Failed to create project"
    else
        echo "Project '$PROJECT_NAME' already exists with ID: $PROJECT_ID"
    fi
}

function add_minio_secret_and_storage_to_project() {
    for (( i=0; i<=TIMEOUT; i+=SLEEP_INTERVAL )); do
        PROJECT_STATUS=$(curl -s -X GET "${AIRM_API_URL}/v1/projects/$PROJECT_ID" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' | jq -r '.status')

        if [ "$PROJECT_STATUS" == "Ready" ]; then
        echo "Project is ready!"
        break # Exit the loop if the project is ready
        fi
        echo "Project status: $PROJECT_STATUS.  Waiting $SLEEP_INTERVAL seconds... ($i/$TIMEOUT seconds elapsed)"
        sleep $SLEEP_INTERVAL
    done

    SECRET_NAME="minio-credentials-fetcher"
    STORAGE_NAME="minio-storage"

    SECRET_IN_PROJECT=$(curl -X 'GET' \
    "${AIRM_API_URL}/v1/projects/${PROJECT_ID}/secrets" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.project_secrets[] | select(.secret.name=="'"$SECRET_NAME"'") | .id')
    EXTERNAL_SECRET_API_VERSION="v1beta1"
    EXTERNAL_SECRET_MANIFEST=$(cat <<EOF
apiVersion: external-secrets.io/${EXTERNAL_SECRET_API_VERSION}
kind: ExternalSecret
metadata:
  name: ${SECRET_NAME}
spec:
  data:
    - remoteRef:
        key: minio-api-access-key
        property: value
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
      secretKey: minio-access-key
    - remoteRef:
        key: minio-api-secret-key
        property: value
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
      secretKey: minio-secret-key
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-secret-store
  target:
    creationPolicy: Owner
    name: minio-credentials
EOF
)
    if [ -z "$SECRET_IN_PROJECT" ] || [ "$SECRET_IN_PROJECT" == "null" ]; then
        echo "Adding secret to project '$PROJECT_ID'..."
        ADD_SECRET_RESP=$(curl -w "%{http_code}" -o /dev/null -X 'POST' \
        "${AIRM_API_URL}/v1/secrets" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{
            "name": "'"$SECRET_NAME"'",
            "project_ids": ["'"$PROJECT_ID"'"],
            "type": "ExternalSecret",
            "use_case": "S3",
            "scope": "Organization",
            "manifest": '"$(echo "$EXTERNAL_SECRET_MANIFEST" | jq -Rs .)"'
        }')
        echo "$ADD_SECRET_RESP"
        check_success "$([[ "$ADD_SECRET_RESP" == "200" || "$ADD_SECRET_RESP" == "201" || "$ADD_SECRET_RESP" == "204" ]] && echo 0 || echo 1)" "Failed to add minio secret to project"
    else
        echo "Secret already exists in project '$PROJECT_ID'."
    fi

    # Check if secret exist and synced
    for (( i=0; i<=TIMEOUT; i+=SLEEP_INTERVAL )); do
        SECRET_RESP=$(curl -s -X GET "${AIRM_API_URL}/v1/secrets" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json')

        SECRET_STATUS=$(echo $SECRET_RESP | jq -r '.secrets[] | select(.name=="'"$SECRET_NAME"'") | .status')
        SECRET_ID=$(echo $SECRET_RESP | jq -r '.secrets[] | select(.name=="'"$SECRET_NAME"'") | .id')

        if [ "$SECRET_STATUS" == "Synced" ] || [ "$SECRET_STATUS" == "Unassigned" ]; then
            echo "Secret is ready!"
            break
        fi
        echo "Secret status: $SECRET_STATUS.  Waiting $SLEEP_INTERVAL seconds... ($i/$TIMEOUT seconds elapsed)"
        sleep $SLEEP_INTERVAL
    done

    STORAGE_IN_PROJECT=$(curl -X 'GET' \
    "${AIRM_API_URL}/v1/projects/${PROJECT_ID}/storages" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.project_storages[] | select(.storage.name=="'"$STORAGE_NAME"'") | .id')

    if [ -z "$STORAGE_IN_PROJECT" ] || [ "$STORAGE_IN_PROJECT" == "null" ]; then
        echo "Adding storage configuration to project '$PROJECT_ID'..."
        ADD_STORAGE_RESP=$(curl -w "%{http_code}" -o /dev/null -X 'POST' \
        "${AIRM_API_URL}/v1/storages" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{
            "name": "'"$STORAGE_NAME"'",
            "project_ids": ["'"$PROJECT_ID"'"],
            "secret_id": "'"$SECRET_ID"'",
            "type": "S3",
            "scope": "Organization",
            "spec": {
                "bucket_url": "http://minio.minio-tenant-default.svc.cluster.local:80",
                "access_key_name": "minio-access-key",
                "secret_key_name": "minio-secret-key"
            }
        }')
        echo "$ADD_STORAGE_RESP"
        check_success "$([[ "$ADD_STORAGE_RESP" == "200" || "$ADD_STORAGE_RESP" == "201" || "$ADD_STORAGE_RESP" == "204" ]] && echo 0 || echo 1)" "Failed to add minio storage to project"
    else
        echo "Storage already exists in project '$PROJECT_ID'."
    fi
}

function add_user_to_project() {
    # Get project id
    USER_IN_PROJECT=$(curl -X 'GET' \
    "${AIRM_API_URL}/v1/users" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r  '.data[] | select(.projects.id=="'"$PROJECT_ID"'" and .email=="'"$USER_EMAIL"'") | .id ')

    USER_ID=$(curl -X 'GET' \
    "${AIRM_API_URL}/v1/users" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r  '.data[] | select(.email=="'"$USER_EMAIL"'") | .id ')

    # Add user to project if they are not already in it
    if [ -z "$USER_IN_PROJECT" ] || [ "$USER_IN_PROJECT" == "null" ]; then
        echo "Adding user '$USER_ID' to project '$PROJECT_ID'..."
        ADD_PROJECT_RESP=$(curl -w "%{http_code}" -o /dev/null -X 'POST' \
        "${AIRM_API_URL}/v1/projects/${PROJECT_ID}/users" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{"user_ids": ["'"${USER_ID}"'"]}')
        echo "$ADD_PROJECT_RESP"
        check_success "$([[ "$ADD_PROJECT_RESP" == "200" || "$ADD_PROJECT_RESP" == "201" || "$ADD_PROJECT_RESP" == "204" ]] && echo 0 || echo 1)" "Failed to add user to project"
    else
        echo "User '$USER_ID' already exists in project '$PROJECT_ID'."
    fi
}

function create_cluster() {
    # Check if cluster exists
    CLUSTER_EXISTS=$(curl -s -X GET "${AIRM_API_URL}/v1/clusters" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' | jq -r '.clusters[] | select(.name=="'$CLUSTER_NAME'") | .id')

    if [ -z "$CLUSTER_EXISTS" ] || [ "$CLUSTER_EXISTS" == "null" ]; then
        # Create cluster
        echo "Creating cluster..."
        CLUSTER=$(curl -X 'POST' \
        "${AIRM_API_URL}/v1/clusters" \
        -H 'accept: application/json' -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{
          "workloads_base_url": "'"$CLUSTER_WORKLOADS_BASE_URL"'",
          "kube_api_url": "'"$CLUSTER_KUBE_API_URL"'"
        }')
        CLUSTER_ID=$(echo "$CLUSTER" | jq -r '.id')
        check_success "$([[ "$CLUSTER_ID" != "null" ]] && echo 0 || echo 1)" "Failed to create cluster"
        CLUSTER_SECRET=$(echo "$CLUSTER" | jq -r '.user_secret')
    else
        echo "Cluster already exists with ID: $CLUSTER_EXISTS"
        CLUSTER_ID=$CLUSTER_EXISTS
    fi
}

function create_secret_and_start_dispatcher() {
    # Cluster was just onboarded and we have a secret
    if [ -n "$CLUSTER_SECRET" ] && [ "$CLUSTER_SECRET" != "null" ]; then
      # Create secret for dispatcher to use
      kubectl create secret generic airm-rabbitmq-common-vhost-user --from-literal=username="$CLUSTER_ID" --from-literal=password="$CLUSTER_SECRET" -n airm

      sleep 10
      # Start dispatcher because it has been failing because secret was not created and wait for 10 seconds
      # kubectl rollout restart deployment/airm-dispatcher -n airm
      echo "Just waiting 10 seconds for dispatcher deployment to rollout and take the secret that has been created"
    else
        echo "Cluster was not onboarded, skipping creating secrets"
    fi
}

function request_password_reset() {
    ADMIN_TOKEN=$(curl -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${KEYCLOAK_ADMIN_CLIENT_ID}" \
        -d "client_secret=${KEYCLOAK_ADMIN_CLIENT_SECRET}" \
        -d 'grant_type=client_credentials' | jq -r '.access_token')

    echo "Retrieved admin token.."

    USER=$(curl -X GET "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?email=${USER_EMAIL}&exact=true" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq '.[0]'
    )
    USER_ID=$(echo "$USER" | jq -r '.id')
    echo "Fetched user ID: $USER_ID"

    UPDATED_USER=$(echo "$USER" | jq '.requiredActions = ["UPDATE_PASSWORD"]')

    UPDATE_USER_RESP=$(curl -w "%{http_code}" -o /dev/null -s -X PUT \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${USER_ID}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${UPDATED_USER}")

    echo "$UPDATE_USER_RESP"

    check_success "$([[ "$UPDATE_USER_RESP" == "200" || "$UPDATE_USER_RESP" == "204" ]] && echo 0 || echo 1)" "Failed to update requiredActions for user ${USER_EMAIL}"
}

function main() {
    refresh_token
    echo "create_org..."
    create_org
    echo ""

    refresh_token
    echo "add_user_to_org..."
    add_user_to_org
    echo ""

    refresh_token
    echo "create_cluster..."
    create_cluster

    # NOTE: Done by airm-configure-dispatcher-rbac.yaml has the deployment failing until this step runs to trigger correctly
    echo "create_secret_and_start_dispatcher..."
    create_secret_and_start_dispatcher
    echo ""

    refresh_token
    echo "create_project..."
    create_project
    refresh_token
    echo "add_user_to_project..."
    add_user_to_project
    echo ""

    echo "add_minio_secret_and_storage_to_project..."
    add_minio_secret_and_storage_to_project

    echo "request_password_reset..."
    request_password_reset
}

main
