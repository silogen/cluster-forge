#!/bin/bash

# Your MinIO root credentials (usually set during installation)
ROOT_USER="rootuser"        # default root user
ROOT_PASSWORD="rootpass123" # default password - replace with your actual root password
BUCKET_NAME_1="cluster-forge-loki-test-dummy"
BUCKET_NAME_2="cluster-forge-mimir-test-dummy"
BUCKET_NAME_3="cluster-forge-tempo-test-dummy"
ALIAS_NAME="cluster-forge-minio"
TENANT_PASSWORD="loki_tenant_pw_fake"

MC_ALIAS="cluster-forge-minio"  # MinIO alias
USER_NAME="test"                # Username
USER_PASSWORD="test-secret"     # User password
POLICY_FILE="loki-policy.json"  # Custom policy file path
SERVICE_ACCOUNT_POLICY="svcacct-loki-access" # Policy for the service account



# Function to cleanup port-forward
cleanup() {
    echo "Cleaning up..."
    kill $PORT_FORWARD_PID
    exit
}

# Set trap for cleanup on script exit
trap cleanup EXIT INT TERM

# Wait for MinIO pod to be in Running state
echo "Waiting for MinIO pod to be in Running state..."
for i in {1..40}; do
    POD_STATUS=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Running" ]; then
        echo "MinIO pod is Running"
        break
    fi
    if [ $i -eq 40 ]; then
        echo "Timeout: MinIO pod failed to reach Running state"
        exit 1
    fi
    sleep 3
done

# Start port-forward in background
kubectl port-forward -n minio svc/minio 9000:9000 &
PORT_FORWARD_PID=$!

# Wait for port-forward to establish
echo "Waiting for port-forward to establish..."
for i in {1..40}; do
    if nc -z localhost 9000; then
        echo "Port-forward is ready"
        break
    fi
    if [ $i -eq 40 ]; then
        echo "Port-forward failed to establish"
        exit 1
    fi
    sleep 1
done

# 1. First configure mc with root credentials
echo "Configuring MinIO client with root credentials..."
mc alias set $ALIAS_NAME http://localhost:9000 $ROOT_USER $ROOT_PASSWORD
if [ $? -ne 0 ]; then
    echo "Error: Failed to configure MinIO alias. Please check your credentials and MinIO server status."
    exit 1
fi


echo "Get bucket list..."
mc ls $ALIAS_NAME
# 2. Create buckets
echo "Creating buckets..."
BUCKET_NAMES=("$BUCKET_NAME_1" "$BUCKET_NAME_2" "$BUCKET_NAME_3") # Array of bucket names

for BUCKET in "${BUCKET_NAMES[@]}"; do
    echo "Creating bucket '${BUCKET}'..."
    mc mb $ALIAS_NAME/$BUCKET >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Bucket '${BUCKET}' created successfully."
    else
        echo "Bucket '${BUCKET}' already exists or could not be created."
    fi
done

# List buckets to verify
echo "Listing all buckets..."
mc ls $ALIAS_NAME

# 3. Run mc admin command and capture the output
echo "Creating MinIO access key..."
# Step 1: Create the test user
echo "Creating user '$USER_NAME'..."
mc admin user add $MC_ALIAS $USER_NAME $USER_PASSWORD

# Create MinIO policy file
cat <<EOF > loki-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::*/*",
                "arn:aws:s3:::*"
            ]
        }
    ]
}
EOF

# Step 2: Create a policy for the bucket access
echo "Creating policy '$SERVICE_ACCOUNT_POLICY'..."
mc admin policy create $MC_ALIAS $SERVICE_ACCOUNT_POLICY $POLICY_FILE

# Step 3: Assign the policy to the user
echo "Assigning policy '$SERVICE_ACCOUNT_POLICY' to user '$USER_NAME'..."
mc admin policy attach $MC_ALIAS readwrite --user $USER_NAME

# Step 4: Create a service account for the test user
echo "Creating service account under user '$USER_NAME'..."
CREDENTIALS=$(mc admin user svcacct add $MC_ALIAS $USER_NAME --policy $POLICY_FILE)

#CREDENTIALS=$(mc admin accesskey create ${ALIAS_NAME})
# 4. Extract Access Key and Secret Key
ACCESS_KEY=$(echo "$CREDENTIALS" | grep "Access Key:" | awk '{print $3}')
SECRET_KEY=$(echo "$CREDENTIALS" | grep "Secret Key:" | awk '{print $3}')

# 5. Print the extracted keys
echo "----------------------------------------"
echo "Access Key: $ACCESS_KEY"
echo "Secret Key: $SECRET_KEY"
echo "----------------------------------------"

# Create a temporary dummy file
echo "This is a test file to verify MinIO access - $(date)" > test.txt
# Upload the test file
echo "Uploading test file to bucket..."
mc cp test.txt cluster-forge-minio//$BUCKET_NAME_1/
# Verify the upload by listing bucket contents
echo "Verifying upload - listing bucket contents:"
mc ls cluster-forge-minio//$BUCKET_NAME_1/


# 6. Create or update Kubernetes secret
echo "Creating or updating Kubernetes secret..."

# Generate the secret YAML file dynamically
cat <<EOF > loki-minio-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: loki-minio-creds
  namespace: grafana-loki
type: Opaque
data:
  access_key_id: $(echo -n $ACCESS_KEY | base64)
  secret_access_key: $(echo -n $SECRET_KEY | base64)
  loki_tenant_pw_fake: $(echo ${TENANT_PASSWORD} | base64)
EOF

cat <<EOF > namespace-grafana-loki.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: grafana-loki
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF

# Apply the secret manifest
kubectl apply -f namespace-grafana-loki.yaml
kubectl apply -f loki-minio-secret.yaml
