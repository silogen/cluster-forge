#!/bin/bash

# Your MinIO root credentials (usually set during installation)
ROOT_USER="rootuser"        # default root user
ROOT_PASSWORD="rootpass123" # default password - replace with your actual root password
BUCKET_NAME="cluster-forge-loki-test-dummy"
ALIAS_NAME="cluster-forge-minio"
TENANT_PASSWORD="loki_tenant_pw_fake"

# Function to cleanup port-forward
cleanup() {
    echo "Cleaning up..."
    kill $PORT_FORWARD_PID
    exit
}

# Set trap for cleanup on script exit
trap cleanup EXIT INT TERM

# Start port-forward in background
kubectl port-forward -n minio svc/minio 9000:9000 &
PORT_FORWARD_PID=$!

# Wait for port-forward to establish
echo "Waiting for port-forward to establish..."
for i in {1..30}; do
    if nc -z localhost 9000; then
        echo "Port-forward is ready"
        break
    fi
    if [ $i -eq 30 ]; then
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
# 2. Create bucket
echo "Creating bucket..."
mc mb $ALIAS_NAME/$BUCKET_NAME >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "Bucket '${BUCKET_NAME}' created successfully."
else
    echo "Bucket '${BUCKET_NAME}' already exists or could not be created."
fi

mc ls $ALIAS_NAME

# 3. Run mc admin command and capture the output
echo "Creating MinIO access key..."
CREDENTIALS=$(mc admin accesskey create ${ALIAS_NAME})

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
mc cp test.txt cluster-forge-minio//$BUCKET_NAME/
# Verify the upload by listing bucket contents
echo "Verifying upload - listing bucket contents:"
mc ls cluster-forge-minio//$BUCKET_NAME/


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
