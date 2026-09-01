# Adding AIM catalog models

Step-by-step guide for cluster operators who need to add, replace, or remove AIM
container images in the AI Workbench model catalog.

For packaged baseline behaviour, version policy, and lifecycle rules, see
[AIM model catalog lifecycle](aim_model_management.md).

Validated with Cluster Forge >= v2.2.2 and AIM Engine 0.2.5.

## Before you start

You need:

- cluster administrator access;
- Gitea and Argo CD web access;
- `kubectl` access for validation;
- an image AIM Engine can inspect (valid AIM metadata); and
- registry reachability from AIM Engine (namespace `aim-system`).

Use images that match the cluster's hardware family. Listing images for other
accelerators creates catalog entries that AI Workbench marks as not deployable.
Active families:

```bash
kubectl get application -n argocd aim-cluster-model-source -o go-template='{{ index (fromYaml .spec.source.helm.values) "hardwareFamilies" }}{{ println }}'
```

...also in Gitea **cluster-values** → `values.yaml` → `apps.aim-cluster-model-source.valuesObject.hardwareFamilies`.
An empty list there selects `templates/unfiltered.yaml` (Instinct 0.11.1+ plus mixed
bases).

For private registries, set `spec.imagePullSecrets` on the source to a secret in
`aim-system`. Do not commit credentials to Gitea.

## One-time setup

Skip this section if `aim-cluster-model-source-additional` is already in
`enabledApps`.

Edit `cluster-org/cluster-values` → `values.yaml` in Gitea:

```yaml
enabledApps:
  # Existing applications remain here.
  - aim-cluster-model-source
  - aim-cluster-model-source-additional

apps:
  # Existing application definitions remain here.

  aim-cluster-model-source-additional:
    repoURL: http://gitea-http.cf-gitea.svc:3000/cluster-org/cluster-values.git
    repoVersion: main
    path: "."
    namespace: kaiwo-system
    syncWave: -20
    directory:
      include: "{cpu-*.yaml,epyc-*.yaml,instinct-*.yaml,radeon-*.yaml}"
```

Commit to `main`, then refresh or sync the `cluster-forge` parent application in
Argo CD.

## Add a model

### 1. Create the manifest in Gitea

1. Open `cluster-org/cluster-values`.
2. **New File** at the repository root.
3. Name the file `{family}-{model}-{version}.yaml`, for example
   `epyc-qwen3-8b-0-13-0.yaml`.
4. Paste a manifest like:

```yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModelSource
metadata:
  name: epyc-qwen3-8b-0-13-0
spec:
  registry: docker.io
  filters:
    - image: amdenterpriseai/aim-epyc-qwen-qwen3-8b:0.13.0
  maxModels: 10
  syncInterval: 15m
```

5. Commit to `main`.

Use immutable names with hardware family, model, and version. Avoid names like
`latest`.

Filename prefixes:

```text
cpu-<model>-<version>.yaml
epyc-<model>-<version>.yaml
instinct-<model>-<version>.yaml
radeon-<model>-<version>.yaml
```

### 2. Sync and verify

Refresh `aim-cluster-model-source-additional` in Argo CD if it does not sync
automatically.

```bash
kubectl get application -n argocd aim-cluster-model-source-additional
kubectl get aimclustermodelsource epyc-qwen3-8b-0-13-0 --watch
kubectl get aimclustermodels \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,STATUS:.status.status
```

Refresh the AI Workbench catalog (or wait at least 30 seconds).

## Add a base image

Same workflow as a model-specific image. Example for an Instinct base tag not
yet in the packaged catalog:

```yaml
apiVersion: aim.eai.amd.com/v1alpha1
kind: AIMClusterModelSource
metadata:
  name: instinct-base-0-13-1
spec:
  registry: docker.io
  filters:
    - image: amdenterpriseai/aim-base:0.13.1
  maxModels: 10
  syncInterval: 1h
```

Save as `instinct-base-0-13-1.yaml`. Base additions should stay
family-specific (`aim-base` on Instinct, `aim-epyc-base` on EPYC, and so on).

## Replace or remove a source

**Do not** remove entries by narrowing filters on an existing source — discovery
is append-only.

**Replace:**

1. Add the new manifest; delete the old one in the same commit.
2. Sync `aim-cluster-model-source-additional` with **prune** enabled.
3. Confirm the old `AIMClusterModelSource` and its models are gone.

**Remove only:**

1. Delete the manifest.
2. Sync with prune enabled.
3. Verify cleanup before disabling the additional application.

```bash
kubectl get aimclustermodelsource <source-name>
kubectl get aimclustermodels
```

## Disable the additional application

Only after all additional sources are removed and pruned:

1. Delete every `{family}-*.yaml` catalog manifest from Gitea.
2. Sync `aim-cluster-model-source-additional` with prune enabled.
3. Confirm no additional `AIMClusterModelSource` resources remain.
4. Remove `aim-cluster-model-source-additional` from `enabledApps`.
5. Sync the `cluster-forge` parent with prune enabled.

Removing the application first leaves orphaned sources in the cluster.

## Before a platform upgrade

1. Review the incoming packaged catalog.
2. Delete additional manifests that duplicate packaged models or bases.
3. Sync with prune enabled.
4. Upgrade only when the additional catalog has no unintended duplicates.

## Troubleshooting

| Symptom | Check |
| --------- | -------- |
| Additional app missing | `enabledApps` entry, `apps` definition, parent `cluster-forge` synced |
| Model remains after app removed | Source was not pruned first — `kubectl delete aimclustermodelsource <name>` |
| Filter removed but model remains | Append-only discovery — delete and replace the source |
| Registry/discovery error | Image tag, reachability, pull secret, AIM Engine logs in `aim-system` |
| Model in K8s but not AI Workbench | `AIMClusterModel` status; refresh catalog; wait 30s |
| Many not-deployable entries | Additional images for wrong hardware family — fix or remove manifests |

See [AIM model catalog lifecycle](aim_model_management.md) for full lifecycle rules.
