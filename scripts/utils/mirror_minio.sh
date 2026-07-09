#!/bin/bash

## ⚠️ Important Disclaimers
##
## This is only an example script only, adjust paths and commands as needed for your system.
## This is for illustration purposes only and **not officially supported.**
##
## Always test backup and restore procedures in a safe environment before relying on them in production.
## The backup and restore process is **not guaranteed to be backwards compatible between two arbitrary versions.** 

# Script to mirror MinIO bucket to local filesystem

# change minio service type to NodePort for better throughput, lower latency, and to avoid potential timeouts 

# Why NodePort is Better than kubectl port-forward for large data transfers:
#  
# ✅ Direct network path to the pod (no API server in the middle)
# ✅ Uses kube-proxy or iptables/ipvs rules (kernel-level routing)
# ✅ Designed for production traffic
# ✅ Can handle multiple parallel connections
# ✅ No timeout issues from API server
# ✅ Better throughput and lower latency✅ Designed for production traffic
# ✅ Can handle multiple parallel connections
# ✅ No timeout issues from API server
# ✅ Better throughput and lower latency

kubectl patch svc minio -n minio-tenant-default -p '{"spec":{"type":"NodePort"}}'

# get the NodePort assigned to the minio service
NODE_PORT=$(kubectl get svc minio -n minio-tenant-default -o jsonpath='{.spec.ports[0].nodePort}')

# set credentials
MINIO_ROOT_USER=$(kubectl get secret default-user -n minio-tenant-default -o jsonpath="{.data.API_ACCESS_KEY}" | base64 --decode)
MINIO_ROOT_PASSWORD=$(kubectl get secret default-user -n minio-tenant-default -o jsonpath="{.data.API_SECRET_KEY}" | base64 --decode)

# install mc (minio client) if not already installed
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod u+x ./mc

# set local alias to point to the minio service
./mc alias set local http://localhost:${NODE_PORT} $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

# mirror to local filesystem, with checksum verification, retries, and logging
mkdir minio_mirror
./mc mirror local/default-bucket minio_mirror \
  --overwrite \
  --remove \
  > >(tee mirror-stdout.log) 2> >(tee mirror-stderr.log >&2)

# cleanup
unset MINIO_ROOT_USER
unset MINIO_ROOT_PASSWORD

# remove the local alias
./mc alias remove local

# revert the minio service type back to ClusterIP
kubectl patch svc minio -n minio-tenant-default -p '{"spec":{"type":"ClusterIP"}}'  
