# AIM model management

Step-by-step guide for cluster operators who need to add, replace, or remove AIM
container images in the AI Workbench model catalog.

For packaged baseline behaviour, version policy, and lifecycle rules, see
[AIM catalog lifecycle](aim_catalog_lifecycle.md).

Validated with Cluster Forge >= v2.2.2 and AIM Engine 0.2.5.

## Table of contents

- [Before you start](#before-you-start)
- [One-time setup](#one-time-setup)
- [Add a model](#add-a-model)
  - [1. Create the manifest in Gitea](#1-create-the-manifest-in-gitea)
  - [2. Sync and verify](#2-sync-and-verify)
- [Add a base image](#add-a-base-image)
- [Replace or remove a source](#replace-or-remove-a-source)
- [Disable the additional application](#disable-the-additional-application)
- [Before a platform upgrade](#before-a-platform-upgrade)
  - [1. Incoming packaged source names](#1-incoming-packaged-source-names)
  - [2. Additional sources on the cluster](#2-additional-sources-on-the-cluster)
  - [3. Confirm the model is not in use](#3-confirm-the-model-is-not-in-use)
  - [4. Prune duplicates, then upgrade](#4-prune-duplicates-then-upgrade)
- [Troubleshooting](#troubleshooting)

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
An empty list there selects `templates/unfiltered.yaml` (Instinct 0.11.1, 0.12.0,
0.13.0 plus mixed bases, including `aim-base:2026.9.0` and `aim-base:2026.9.1`).
The Instinct 2026.9.0 model source is only on the `profiles.yaml` / `instinct`
path.

For private registries, set `spec.imagePullSecrets` on the source to a secret in
`aim-system`. Do not commit credentials to Gitea.

## One-time setup

Skip this section if the additional application already exists:

```bash
kubectl get application -n argocd aim-cluster-model-source-additional
```

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
kubectl get aimclsrc epyc-qwen3-8b-0-13-0 --watch
kubectl get aimclmdl -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,STATUS:.status.status,AIM:.status.imageMetadata.model.canonicalName
```

`aimclsrc` / `aimclmdl` / `aimsvc` are the AIM Engine short names for
`AIMClusterModelSource`, `AIMClusterModel`, and `AIMService`.

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
is append-only. The image stays in the catalog as an `AIMClusterModel` until the
source itself is deleted. Emptying `spec.filters` is not a workaround: the CRD
requires at least one filter or image.

Deleting the source **is** how models leave the catalog, and it is a breaking
change for anything still using them: Argo CD prune removes the
`AIMClusterModelSource`, then Kubernetes garbage-collects its owned
`AIMClusterModel` resources. Confirm no `AIMService` still selects those
images before you prune (see the in-use check under
[Before a platform upgrade](#before-a-platform-upgrade)). See
[Filter removal vs source removal](aim_catalog_lifecycle.md#filter-removal-vs-source-removal).

**Replace:**

1. Add the new manifest; delete the old one in the same commit.
2. Sync `aim-cluster-model-source-additional` with **prune** enabled.
3. Confirm the old `AIMClusterModelSource` and its models are gone.

**Remove only:**

1. Delete the manifest.
2. Sync with prune enabled.
3. Verify cleanup before disabling the additional application.

```bash
kubectl get aimclsrc <source-name>
kubectl get aimclmdl -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{"\t"}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep '^<source-name>'$'\t' || true
```

## Disable the additional application

Only after all additional sources are removed and pruned:

1. Delete every `{family}-*.yaml` catalog manifest from Gitea.
2. Sync `aim-cluster-model-source-additional` with prune enabled.
3. Confirm no additional `AIMClusterModelSource` resources remain:
   `kubectl get aimclsrc -l argocd.argoproj.io/instance=aim-cluster-model-source-additional`
4. Remove `aim-cluster-model-source-additional` from `enabledApps`.
5. Sync the `cluster-forge` parent with prune enabled.

Removing the application first leaves orphaned sources in the cluster.

## Before a platform upgrade

Deleting an additional source garbage-collects every `AIMClusterModel` it owns
and **breaks** any `AIMService` still bound to those models. Finish this
checklist **before** you change `global.targetRevision` (or otherwise sync the
incoming Cluster Forge chart).

### 1. Incoming packaged source names

On a checkout of the Cluster Forge revision you are upgrading **to**, render
the chart for this cluster's `hardwareFamilies` (same list as
[Before you start](#before-you-start)):

```bash
helm template aim-cluster-model-source sources/aim-cluster-model-source \
  --set-json 'hardwareFamilies=["instinct"]' \
  | awk '/^kind: AIMClusterModelSource/{want=1; next} want && /^  name:/{print $2; want=0}'
```

Images those sources will list:

```bash
helm template aim-cluster-model-source sources/aim-cluster-model-source \
  --set-json 'hardwareFamilies=["instinct"]' \
  | awk '/^  name:/{n=$2} /^    - image:/{print n, $NF} /^  - amdenterpriseai/{print n, $2}'
```

### 2. Additional sources on the cluster

```bash
kubectl get aimclsrc -l argocd.argoproj.io/instance=aim-cluster-model-source-additional \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.status,MODELS:.status.discoveredModels
kubectl get aimclsrc -l argocd.argoproj.io/instance=aim-cluster-model-source-additional \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.filters[*]}  {.image}{"\n"}{end}{range .spec.images[*]}  {.}{"\n"}{end}{end}'
```

Delete a Gitea `{family}-*.yaml` only when its image(s) already appear in the
incoming `helm template` output (duplicate of a newly packaged model or base).
Leave additional sources whose images are **not** in that list.

### 3. Confirm the model is not in use

List every `AIMService` and how it selects a model:

```bash
kubectl get aimsvc -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.status,SPEC_NAME:.spec.model.name,SPEC_IMAGE:.spec.model.image,RESOLVED:.status.resolvedModel.name
```

`SPEC_NAME` is `spec.model.name` (an `AIMClusterModel` / `AIMModel` object
name). `SPEC_IMAGE` is `spec.model.image`. `RESOLVED` is
`status.resolvedModel.name`. Exactly one of `name` / `image` / `custom` is set
on each service.

Models owned by one additional source (replace `SRC`):

```bash
SRC=epyc-qwen3-8b-0-13-0
kubectl get aimclmdl -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].name}{"\t"}{.metadata.name}{"\t"}{.spec.image}{"\n"}{end}' | grep "^${SRC}"$'\t'
```

Fail the prune if that image (or cluster-model object name) is still selected
by any service — **empty grep means not in use**:

```bash
kubectl get aimsvc -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.model.name}{"\t"}{.spec.model.image}{"\t"}{.status.resolvedModel.name}{"\n"}{end}' \
  | grep -F -- 'amdenterpriseai/aim-epyc-qwen-qwen3-8b:0.13.0'
```

Do not delete the additional source while this grep prints rows. Stopping
discovery without tearing down running services means **leave the source
name in Gitea**; narrowing filters does not remove already-discovered models.

### 4. Prune duplicates, then upgrade

1. Delete the duplicate additional manifests in Gitea (`cluster-values`).
2. Sync `aim-cluster-model-source-additional` in Argo CD with **prune** enabled.
3. Re-run the `aimclsrc` list in step 2 — intended duplicates should be gone.
4. Upgrade the Enterprise AI reference stack only after that list has no leftover packaged
   duplicates.

## Troubleshooting

| Symptom | Check |
| --------- | -------- |
| Additional app missing | `kubectl get application -n argocd aim-cluster-model-source-additional`; `enabledApps` + `apps` in Gitea; parent `cluster-forge` synced |
| Model remains after app removed | Source was not pruned first — `kubectl delete aimclsrc <name>` (breaks in-use `AIMService`s) |
| Filter removed but model remains | Append-only discovery — delete and replace the source |
| Registry/discovery error | Image tag, reachability, pull secret; `kubectl logs -n aim-system -l control-plane=controller-manager --tail=100` |
| Model in K8s but not AI Workbench | `kubectl get aimclmdl`; refresh catalog; wait 30s |
| Many not-deployable entries | Additional images for wrong hardware family — fix or remove manifests |
| Unsure if a model is live | In-use `aimsvc` grep in [Before a platform upgrade](#before-a-platform-upgrade) |

See [AIM catalog lifecycle](aim_catalog_lifecycle.md) for full lifecycle rules.
