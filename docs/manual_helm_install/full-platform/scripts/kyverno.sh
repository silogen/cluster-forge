#!/usr/bin/env bash
# Kyverno 3.5.1, and the ClusterPolicy that makes a ReadWriteOnce storage class
# usable.
#
# The AIM engine creates the model artifact cache PVC with ReadWriteMany. The
# local-path provisioner supports ReadWriteOnce only, so the PVC stays Pending
# and no model can start. cluster-forge solves this with the ClusterPolicy
# local-path-access-mode-mutation, which it installs on a small or a medium
# cluster and not on a large cluster, because a large cluster uses Longhorn.
# This script applies the same policy.
#
# RWX_MUTATION selects the behaviour. auto (the default) applies the policy when
# the provisioner of STORAGE_CLASS is rancher.io/local-path. on applies it
# always. off applies it never.
#
# Kyverno is also required when AIWB is installed with standAloneMode=true.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RWX_MUTATION="${RWX_MUTATION:-auto}"

helm repo add --force-update kyverno https://kyverno.github.io/kyverno/
helm repo update kyverno
helm upgrade --install kyverno kyverno/kyverno --version 3.5.1 \
  --namespace kyverno --create-namespace \
  --wait --timeout 6m

storage_class_is_rwo_only() {
  local provisioner
  provisioner="$(kubectl get storageclass "${STORAGE_CLASS}" \
    -o jsonpath='{.provisioner}' 2>/dev/null || true)"
  [[ "${provisioner}" == "rancher.io/local-path" ]]
}

apply_access_mode_policy() {
  kubectl apply --filename - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: local-path-access-mode-mutation
  annotations:
    policies.kyverno.io/title: "Local-Path Access Mode Mutation"
    policies.kyverno.io/category: "Storage"
    policies.kyverno.io/subject: "PersistentVolumeClaim"
spec:
  admission: true
  background: false
  validationFailureAction: Enforce
  rules:
    - name: convert-rwx-rox-to-rwo
      match:
        resources:
          kinds:
            - PersistentVolumeClaim
      preconditions:
        any:
          - key: "ReadWriteMany"
            operator: AnyIn
            value: "{{ request.object.spec.accessModes || [] }}"
          - key: "ReadOnlyMany"
            operator: AnyIn
            value: "{{ request.object.spec.accessModes || [] }}"
      mutate:
        patchStrategicMerge:
          spec:
            accessModes:
              - ReadWriteOnce
          metadata:
            annotations:
              +(kyverno.io/original-access-modes): "{{ request.object.spec.accessModes && join(',', request.object.spec.accessModes) || 'undefined' }}"
              +(kyverno.io/mutation-applied): "local-path-rwx-to-rwo"
              +(kyverno.io/policy-reason): "local-path provisioner only supports ReadWriteOnce and ReadWriteOncePod"
EOF
  kubectl wait --for=condition=Ready clusterpolicy/local-path-access-mode-mutation \
    --timeout=120s
}

case "${RWX_MUTATION}" in
  on)
    apply_access_mode_policy
    ;;
  off)
    echo "RWX_MUTATION=off. The access mode policy is not applied."
    ;;
  auto)
    if storage_class_is_rwo_only; then
      echo "${STORAGE_CLASS} supports ReadWriteOnce only. Applying the policy."
      apply_access_mode_policy
    else
      echo "${STORAGE_CLASS} is not local-path. The access mode policy is not needed."
    fi
    ;;
  *)
    echo "RWX_MUTATION must be auto, on or off. Got ${RWX_MUTATION}." >&2
    exit 1
    ;;
esac
