# PVC access modes and the local-path Kyverno rewrite

This document tells which access mode each PersistentVolumeClaim (PVC)
requests on each cluster size. It also tells when the
`local-path-access-mode-mutation` Kyverno policy is still necessary.

## Storage per cluster size

| Cluster size | StorageClasses | ReadWriteMany (RWX) |
|--------------|----------------|---------------------|
| Small | `local-path` (`rancher.io/local-path`) | No |
| Medium | `local-path` (`rancher.io/local-path`) | No |
| Large | Longhorn: `default`, `mlstorage`, `multinode`, `direct` | Yes, except `direct` |

The local-path provisioner supports only ReadWriteOnce (RWO) and
ReadWriteOncePod (RWOP). If a PVC requests RWX or ReadOnlyMany (ROX), the
provisioner does not bind it. The error is
`NodePath only supports ReadWriteOnce and ReadWriteOncePod`.

The Longhorn `direct` class is strict-local, so it cannot serve RWX.

## Rule: request the correct mode at the source

Each PVC requests the access mode that its storage can serve. Do not
request RWX and rely on a policy to change it.

- Small and medium: platform PVCs request RWO.
- Large: a PVC requests RWX only if more than one node must mount the
  volume. All other PVCs request RWO.

Set the mode in the chart values or in `root/values_{small,medium,large}.yaml`.

## User PVCs from `dynamic-pvc-creation`

The `dynamic-pvc-creation` policy in `sources/kyverno-policies/base` makes
`pvc-<uid>` for a Deployment or Pod that has the
`pvc.silogen.ai/user-pvc-*` annotations. The policy sets the access mode from
the storage class annotation:

- RWX, if the storage class is in `dynamicPvc.readWriteManyStorageClasses`.
- RWO, for all other storage classes.

| Cluster size | `readWriteManyStorageClasses` | Result on `local-path` |
|--------------|-------------------------------|------------------------|
| Small | `[]` (chart default) | RWO |
| Medium | `[]` (chart default) | RWO |
| Large | `[default, mlstorage, multinode]` (`root/values_large.yaml`) | Not applicable |

Thus `dynamic-pvc-creation` never makes an RWX PVC on `local-path`. If
cluster-bloom adds a Longhorn class that can serve RWX, add it to the list in
`root/values_large.yaml`.

## `local-path-access-mode-mutation`

The `kyverno-policies-storage-local-path` application deploys this policy.
The policy changes RWX and ROX to RWO when a PVC is created.

| Cluster size | Policy deployed | Why |
|--------------|-----------------|-----|
| Small | No | Platform PVCs request RWO. |
| Medium | No | Platform PVCs request RWO. |
| Large | No | Longhorn serves RWX. |
| OpenShift | Yes | `values-openshift.yaml` uses local-path and scoped copies of the policy. |

Some operators still make RWX PVCs at runtime. On small and medium these
PVCs stay Pending with `NodePath only supports ReadWriteOnce and
ReadWriteOncePod`:

- aim-engine 0.2.7 makes all model cache PVCs as RWX and has no setting to
  change this.
- kaiwo v0.2.1 sets `storage.accessMode: ReadWriteMany` as the default in
  `KaiwoJob` and `KaiwoService`. Set `ReadWriteOnce` in the workload.

The policy has a known defect: it can block an update of a PVC that already
exists as RWX. Refer to EAI-9316.

## Existing clusters

The access mode of a PVC cannot change after the PVC is created. A new value
in Git does not change an existing PVC.

- `kaiwo-config` has `ignoreDifferences` on `/spec/accessModes` for
  `pvc-user-demo`. A large cluster that has this PVC as RWX keeps it, and
  Argo CD does not show a diff.
- To get the new mode on an existing cluster, delete the PVC. Argo CD makes
  it again. Delete the PVC only if it has no data that you must keep.
- If you remove `kyverno-policies-storage-local-path` from a cluster,
  Argo CD does not delete the ClusterPolicy, because the Application has no
  resources finalizer. Delete it manually:

  ```bash
  kubectl delete clusterpolicy local-path-access-mode-mutation local-path-access-mode-warning
  ```

## Verify

```bash
# Access mode and storage class of all PVCs
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MODES:.spec.accessModes,SC:.spec.storageClassName,STATUS:.status.phase

# Policies on the cluster
kubectl get clusterpolicy
```

On small, medium and large, `local-path-access-mode-mutation` is not in the list.
