#!/usr/bin/env bash
# SeaweedFS operator 0.1.36 and seaweedfs-config.
# S3 endpoint http://filer-s3.seaweedfs-instance.svc.cluster.local:80 (AIWB minio.url default).
# Access key matches minio-credentials and the OpenBao minio keys.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

forge="$(forge_dir)"
s3_json="$(printf '{"identities":[{"name":"ApiUser","actions":["Admin"],"credentials":[{"accessKey":"%s","secretKey":"%s"}]}]}' \
  "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}")"

helm upgrade --install seaweedfs-operator "${forge}/sources/seaweedfs-operator/0.1.36" \
  --namespace seaweedfs-operator --create-namespace \
  --wait --timeout 6m

ensure_ns seaweedfs-instance
ksecret seaweedfs-instance seaweedfs-s3-config \
  --from-literal=s3.json="${s3_json}"
ksecret seaweedfs-instance seaweedfs-admin-secret \
  --from-literal=admin-password="${SEAWEED_ADMIN_PASSWORD}"

helm upgrade --install seaweedfs-config "${forge}/sources/seaweedfs-config" \
  --namespace seaweedfs-instance \
  --set domain="${DOMAIN}" \
  --set seaweed.storageClassName="${STORAGE_CLASS}" \
  --wait --timeout 10m
