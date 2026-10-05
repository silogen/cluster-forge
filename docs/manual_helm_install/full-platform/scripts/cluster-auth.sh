#!/usr/bin/env bash
# In-memory cluster-auth on cluster-auth.cluster-auth.svc.cluster.local:8081.
# State is lost when the pod restarts. Secret cluster-auth-admin-token still has to exist in aiwb.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The aiwb-standalone guide owns the only copy of the shim, so that the two
# guides cannot drift apart.
SHIM_PY="${SHIM_PY:-${DEPS_DIR}/../../aiwb-standalone/scripts/cluster-auth-shim.py}"

ensure_ns cluster-auth
kubectl create configmap cluster-auth-shim --namespace cluster-auth \
  --from-file="shim.py=${SHIM_PY}" \
  --dry-run=client --output yaml | kubectl apply --filename -

kubectl apply --filename - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-auth
  template:
    metadata:
      labels:
        app: cluster-auth
    spec:
      containers:
        - name: shim
          image: python:3.11-slim
          command: ["python3", "/shim/shim.py"]
          ports:
            - containerPort: 8081
          volumeMounts:
            - name: shim
              mountPath: /shim
      volumes:
        - name: shim
          configMap:
            name: cluster-auth-shim
---
apiVersion: v1
kind: Service
metadata:
  name: cluster-auth
  namespace: cluster-auth
spec:
  selector:
    app: cluster-auth
  ports:
    - name: rest-api
      port: 8081
      targetPort: 8081
EOF
