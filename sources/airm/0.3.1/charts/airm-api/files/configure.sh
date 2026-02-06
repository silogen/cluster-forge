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
check_env_variable "USER_PASSWORD"

function refresh_token() {
    echo "Attempting to obtain access token from Keycloak..."
    
    # Build the full URL for debugging
    FULL_URL="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
    echo "Target URL: $FULL_URL"
    
    # Test basic connectivity with retries
    echo "Testing connectivity to Keycloak server..."
    CONNECTIVITY_OK=false
    for i in {1..5}; do
        if curl -s --connect-timeout 5 --max-time 10 -f "$KEYCLOAK_URL" > /dev/null 2>&1; then
            echo "Basic connectivity to Keycloak server: OK (attempt $i)"
            CONNECTIVITY_OK=true
            break
        else
            echo "Connectivity test attempt $i failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    if [ "$CONNECTIVITY_OK" = false ]; then
        echo "WARNING: Basic connectivity test to $KEYCLOAK_URL failed after 5 attempts"
    fi
    
    # Create a temporary file to capture response
    CURL_RESPONSE_FILE=$(mktemp)
    
    # Execute the token request - get response body and HTTP code separately
    HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 30 \
        -w "%{http_code}" \
        -d "client_id=${KEYCLOAK_CLIENT_ID}" \
        -d "username=${USER_EMAIL}" \
        -d "password=${USER_PASSWORD}" \
        -d 'grant_type=password' \
        -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
        -o "$CURL_RESPONSE_FILE" \
        "$FULL_URL")
    
    CURL_EXIT_CODE=$?
    
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "ERROR: curl command failed when connecting to Keycloak"
        echo "Curl exit code: $CURL_EXIT_CODE"
        echo ""
        echo "Debugging information:"
        echo "- Full URL: $FULL_URL"
        echo "- KEYCLOAK_URL: ${KEYCLOAK_URL}"
        echo "- KEYCLOAK_REALM: ${KEYCLOAK_REALM}"
        echo "- KEYCLOAK_CLIENT_ID: ${KEYCLOAK_CLIENT_ID}"
        echo "- USER_EMAIL: ${USER_EMAIL}"
        echo "- DNS resolution test:"
        HOSTNAME=$(echo "$KEYCLOAK_URL" | sed 's|https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
        nslookup "$HOSTNAME" || echo "DNS lookup failed for $HOSTNAME"
        
        rm -f "$CURL_RESPONSE_FILE"
        exit 1
    fi
    
    echo "HTTP Status Code: $HTTP_CODE"
    
    # Read the response body from the temporary file
    RESPONSE_BODY=$(cat "$CURL_RESPONSE_FILE")
    
    # Clean up temp file
    rm -f "$CURL_RESPONSE_FILE"
    
    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERROR: HTTP request failed with status code $HTTP_CODE"
        echo "Response body: $RESPONSE_BODY"
        exit 1
    fi
    
    # Check if response looks like a JWT (starts with eyJ)
    if [[ "$RESPONSE_BODY" =~ ^\{.*access_token.*\} ]]; then
        # This is a proper JSON response
        TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.access_token')
    elif [[ "$RESPONSE_BODY" =~ ^eyJ ]]; then
        # This is just a raw JWT token
        TOKEN="$RESPONSE_BODY"
    else
        # Try to parse as JSON first
        TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.access_token' 2>/dev/null)
    fi
    
    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo "ERROR: Failed to obtain access token from Keycloak."
        echo "Full response from Keycloak:"
        echo "$RESPONSE_BODY" | jq '.' 2>/dev/null || echo "$RESPONSE_BODY"
        
        ERROR_MSG=$(echo "$RESPONSE_BODY" | jq -r '.error_description // .error // "No error details available"' 2>/dev/null)
        echo "Error details: $ERROR_MSG"
        
        echo "Request parameters:"
        echo "- KEYCLOAK_URL: ${KEYCLOAK_URL}"
        echo "- KEYCLOAK_REALM: ${KEYCLOAK_REALM}"
        echo "- KEYCLOAK_CLIENT_ID: ${KEYCLOAK_CLIENT_ID}"
        echo "- USER_EMAIL: ${USER_EMAIL}"
        echo "- CLIENT_SECRET: [HIDDEN]"
        
        exit 1
    fi
    
    echo "Successfully obtained access token"
}

function create_project() {
    # Validate CLUSTER_ID exists before proceeding
    if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "null" ]; then
        echo "ERROR: CLUSTER_ID is not set. Cannot proceed with project creation."
        exit 1
    fi
    
    echo "Checking for existing project '$PROJECT_NAME'..."
    
    # Get list of projects with proper error handling
    PROJECTS_RESPONSE=$(mktemp)
    HTTP_CODE=$(curl -s -L -w "%{http_code}" -X GET "${AIRM_API_URL}/v1/projects" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer ${TOKEN}" \
        -o "$PROJECTS_RESPONSE")
    
    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERROR: Failed to get projects list. HTTP Status: $HTTP_CODE"
        echo "Response:"
        cat "$PROJECTS_RESPONSE"
        rm -f "$PROJECTS_RESPONSE"
        exit 1
    fi
    
    PROJECT_ID=$(cat "$PROJECTS_RESPONSE" | jq -r '.data[]? | select(.name=="'$PROJECT_NAME'") | .id' 2>/dev/null)
    rm -f "$PROJECTS_RESPONSE"
    
    echo "Waiting for cluster '$CLUSTER_ID' to become healthy..."
    for (( i=0; i<=TIMEOUT; i+=SLEEP_INTERVAL )); do
        CLUSTER_RESPONSE=$(mktemp)
        HTTP_CODE=$(curl -s -L -w "%{http_code}" -X GET "${AIRM_API_URL}/v1/clusters/$CLUSTER_ID" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H 'Content-Type: application/json' \
            -o "$CLUSTER_RESPONSE")
        
        if [ "$HTTP_CODE" != "200" ]; then
            echo "WARNING: Failed to get cluster status. HTTP Status: $HTTP_CODE (attempt $((i/SLEEP_INTERVAL + 1)))"
            rm -f "$CLUSTER_RESPONSE"
        else
            CLUSTER_STATUS=$(cat "$CLUSTER_RESPONSE" | jq -r '.status' 2>/dev/null)
            rm -f "$CLUSTER_RESPONSE"
            
            if [ "$CLUSTER_STATUS" == "healthy" ]; then
                echo "Cluster is healthy!"
                break
            fi
        fi
        
        echo "Cluster status: $CLUSTER_STATUS. Waiting $SLEEP_INTERVAL seconds... ($i/$TIMEOUT seconds elapsed)"
        sleep $SLEEP_INTERVAL
    done

    if [ "$CLUSTER_STATUS" != "healthy" ]; then
        echo "ERROR: Cluster did not become healthy within $TIMEOUT seconds. Last status: $CLUSTER_STATUS"
        exit 1
    fi

    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" == "null" ]; then
        echo "Project '$PROJECT_NAME' not found. Creating..."
        
        PROJECT_RESPONSE=$(mktemp)
        HTTP_CODE=$(curl -L -w "%{http_code}" -X 'POST' \
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
            }' \
            -o "$PROJECT_RESPONSE")
        
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            PROJECT_ID=$(cat "$PROJECT_RESPONSE" | jq -r '.id' 2>/dev/null)
            echo "Project created successfully with ID: $PROJECT_ID"
        else
            echo "ERROR: Failed to create project. HTTP Status: $HTTP_CODE"
            echo "Response:"
            cat "$PROJECT_RESPONSE"
            rm -f "$PROJECT_RESPONSE"
            exit 1
        fi
        
        rm -f "$PROJECT_RESPONSE"
        check_success "$([[ "$PROJECT_ID" != "null" && -n "$PROJECT_ID" ]] && echo 0 || echo 1)" "Failed to get valid project ID"
    else
        echo "Project '$PROJECT_NAME' already exists with ID: $PROJECT_ID"
    fi
}

function add_minio_secret_and_storage_to_project() {
    for (( i=0; i<=TIMEOUT; i+=SLEEP_INTERVAL )); do
        PROJECT_STATUS=$(curl -s -L -X GET "${AIRM_API_URL}/v1/projects/$PROJECT_ID" \
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

    SECRET_IN_PROJECT=$(curl -L -X 'GET' \
    "${AIRM_API_URL}/v1/projects/${PROJECT_ID}/secrets" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.data[] | select(.secret.name=="'"$SECRET_NAME"'") | .id')
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
        ADD_SECRET_RESP=$(curl -L -w "%{http_code}" -o /dev/null -X 'POST' \
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
        SECRET_RESP=$(curl -s -L -X GET "${AIRM_API_URL}/v1/secrets" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json')

        SECRET_STATUS=$(echo $SECRET_RESP | jq -r '.data[] | select(.name=="'"$SECRET_NAME"'") | .status')
        SECRET_ID=$(echo $SECRET_RESP | jq -r '.data[] | select(.name=="'"$SECRET_NAME"'") | .id')

        if [ "$SECRET_STATUS" == "Synced" ] || [ "$SECRET_STATUS" == "Unassigned" ]; then
            echo "Secret is ready!"
            break
        fi
        echo "Secret status: $SECRET_STATUS.  Waiting $SLEEP_INTERVAL seconds... ($i/$TIMEOUT seconds elapsed)"
        sleep $SLEEP_INTERVAL
    done

    STORAGE_IN_PROJECT=$(curl -L -X 'GET' \
    "${AIRM_API_URL}/v1/projects/${PROJECT_ID}/storages" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.data[] | select(.storage.name=="'"$STORAGE_NAME"'") | .id')

    if [ -z "$STORAGE_IN_PROJECT" ] || [ "$STORAGE_IN_PROJECT" == "null" ]; then
        echo "Adding storage configuration to project '$PROJECT_ID'..."
        ADD_STORAGE_RESP=$(curl -L -w "%{http_code}" -o /dev/null -X 'POST' \
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
    USER_IN_PROJECT=$(curl -L -X 'GET' \
    "${AIRM_API_URL}/v1/users" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r  '.data[] | select(.projects.id=="'"$PROJECT_ID"'" and .email=="'"$USER_EMAIL"'") | .id ')

    USER_ID=$(curl -L -X 'GET' \
    "${AIRM_API_URL}/v1/users" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer ${TOKEN}" | jq -r  '.data[] | select(.email=="'"$USER_EMAIL"'") | .id ')

    # Add user to project if they are not already in it
    if [ -z "$USER_IN_PROJECT" ] || [ "$USER_IN_PROJECT" == "null" ]; then
        echo "Adding user '$USER_ID' to project '$PROJECT_ID'..."
        ADD_PROJECT_RESP=$(curl -L -w "%{http_code}" -o /dev/null -X 'POST' \
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
    # Test AIRM API connectivity first
    echo "Testing connectivity to AIRM API: ${AIRM_API_URL}"
    AIRM_HOST=$(echo "${AIRM_API_URL}" | sed 's|http[s]*://||' | cut -d'/' -f1)
    echo "Resolving hostname: $AIRM_HOST"
    nslookup "$AIRM_HOST" || echo "DNS lookup failed for $AIRM_HOST"
    
    echo "Checking for existing cluster '$CLUSTER_NAME'..."
    
    # Check if cluster exists with proper error handling
    CLUSTERS_RESPONSE=$(mktemp)
    HTTP_CODE=$(curl -s -L -w "%{http_code}" -X GET "${AIRM_API_URL}/v1/clusters" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/json' \
        -o "$CLUSTERS_RESPONSE")
    
    if [ "$HTTP_CODE" != "200" ]; then
        echo "ERROR: Failed to get clusters list. HTTP Status: $HTTP_CODE"
        echo "Response:"
        cat "$CLUSTERS_RESPONSE"
        rm -f "$CLUSTERS_RESPONSE"
        exit 1
    fi
    
    # Safely parse response - check if data array exists
    CLUSTERS_DATA=$(cat "$CLUSTERS_RESPONSE" | jq -r '.data' 2>/dev/null)
    if [ "$CLUSTERS_DATA" == "null" ] || [ -z "$CLUSTERS_DATA" ]; then
        echo "No clusters found in response (data field is null or missing)"
        CLUSTER_EXISTS=""
    else
        CLUSTER_EXISTS=$(cat "$CLUSTERS_RESPONSE" | jq -r '.data[]? | select(.name=="'$CLUSTER_NAME'") | .id' 2>/dev/null)
    fi
    rm -f "$CLUSTERS_RESPONSE"

    if [ -z "$CLUSTER_EXISTS" ] || [ "$CLUSTER_EXISTS" == "null" ]; then
        echo "Cluster '$CLUSTER_NAME' not found. Creating new cluster..."
        
        CLUSTER_RESPONSE=$(mktemp)
        HTTP_CODE=$(curl -L -w "%{http_code}" -X 'POST' \
            "${AIRM_API_URL}/v1/clusters" \
            -H 'accept: application/json' \
            -H "Authorization: Bearer ${TOKEN}" \
            -H 'Content-Type: application/json' \
            -d '{
              "workloads_base_url": "'"$CLUSTER_WORKLOADS_BASE_URL"'",
              "kube_api_url": "'"$CLUSTER_KUBE_API_URL"'"
            }' \
            -o "$CLUSTER_RESPONSE")
        
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            CLUSTER_ID=$(cat "$CLUSTER_RESPONSE" | jq -r '.id' 2>/dev/null)
            CLUSTER_SECRET=$(cat "$CLUSTER_RESPONSE" | jq -r '.user_secret' 2>/dev/null)
            echo "Cluster created successfully with ID: $CLUSTER_ID"
        else
            echo "ERROR: Failed to create cluster. HTTP Status: $HTTP_CODE"
            echo "Response:"
            cat "$CLUSTER_RESPONSE"
            rm -f "$CLUSTER_RESPONSE"
            exit 1
        fi
        
        rm -f "$CLUSTER_RESPONSE"
        check_success "$([[ "$CLUSTER_ID" != "null" && -n "$CLUSTER_ID" ]] && echo 0 || echo 1)" "Failed to get valid cluster ID"
    else
        echo "Cluster '$CLUSTER_NAME' already exists with ID: $CLUSTER_EXISTS"
        CLUSTER_ID=$CLUSTER_EXISTS
        CLUSTER_SECRET=""  # Existing clusters don't return user_secret
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

function main() {
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
}

main
