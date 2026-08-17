# Managing AIM Catalog Models Between Releases

This guide explains how a platform administrator can add AIM container images
to the AI Workbench model catalog between Cluster Forge releases. The workflow
keeps the packaged model catalog intact and manages additional catalog sources
through the cluster's Gitea and Argo CD instances.

This development and validation workflow was validated with Cluster Forge
`v2.2.2` and AIM Engine `0.2.5`. It is not a replacement for publishing models
through the normal AIM and platform release process.

## How catalog management works

Cluster Forge installs a baseline `aim-cluster-model-source` Argo CD
application. Its `AIMClusterModelSource` resources are selected by the
`AIM_HARDWARE_FAMILY` value supplied to cluster-bloom.

An administrator can add a second application,
`aim-cluster-model-source-additional`, whose manifests live in the
cluster-local `cluster-values` repository:

1. Gitea stores the additional `AIMClusterModelSource` manifests.
2. The `cluster-forge` parent application reads `cluster-values/values.yaml`
   and creates the additional child application.
3. The child application applies the model sources.
4. AIM Engine discovers the referenced images and creates
   `AIMClusterModel` resources.
5. AI Workbench reads those resources and refreshes its catalog periodically.

The node does not need matching hardware for a model to appear in the catalog.
Missing hardware affects whether the model is supported and deployable, not
whether the catalog resource is listed.

## Lifecycle constraints

Keep these behaviors in mind:

- Discovery is additive. Adding an image filter can create another
  `AIMClusterModel`.
- Removing a filter from an existing source does not remove models that were
  already discovered.
- Removing the child Argo CD `Application` does not delete its resources
  because generated child applications do not have a cascading-resources
  finalizer.
- Deleting an `AIMClusterModelSource` removes its source-owned models through
  Kubernetes garbage collection.

Consequently, remove or replace source manifests while the additional
application still exists. Remove the application only after its sources have
been pruned.

## Prerequisites

You need:

- cluster administrator access;
- access to the cluster's Gitea and Argo CD web interfaces;
- `kubectl` access for validation;
- a container image that AIM Engine can inspect and that contains valid AIM
  metadata; and
- network and registry access from AIM Engine to that image.

The example below uses a public image. For a private registry, set
`spec.imagePullSecrets` on the model source to a secret available to AIM Engine
in its operator namespace, normally `aim-system`. Follow your registry's
credential-management procedure rather than committing credentials to Gitea.

## Select the initial catalog

For an Instinct-only baseline on a medium cluster, configure cluster-bloom
before the initial installation:

```yaml
CLUSTER_SIZE: medium
AIM_HARDWARE_FAMILY: instinct
```

Cluster-bloom writes the selection to the cluster-local
`cluster-values/values.yaml`:

```yaml
apps:
  aim-cluster-model-source:
    valuesObject:
      hardwareFamilies:
        - instinct
```

After installation, confirm that the baseline application and sources are
healthy:

```bash
kubectl get application -n argocd aim-cluster-model-source
kubectl get aimclustermodelsources
kubectl get aimclustermodels
```

## Add an additional model source

### 1. Create the source manifest in Gitea

In the Gitea web interface:

1. Open `cluster-org/cluster-values`.
2. Select **New File**.
3. Name the root-level file `epyc-qwen3-8b-0-13-0.yaml`.
4. Add the following manifest:

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

5. Commit the file to `main`.

Use immutable, descriptive source names containing the hardware family, model,
and version. Do not use names such as `latest`.

### 2. Enable the additional application

Edit the existing `cluster-values/values.yaml` in Gitea.

Append the application name to the existing `enabledApps` list. Do not replace
or duplicate the list:

```yaml
enabledApps:
  # Existing applications remain here.
  - aim-cluster-model-source
  - aim-cluster-model-source-additional
```

Add the application definition under the existing `apps` map:

```yaml
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

The include expression is important. It allows one root-level file per
hardware-specific source while preventing Argo CD from treating
`cluster-values/values.yaml` as a Kubernetes manifest.

Commit the change to `main`.

### 3. Sync the parent application

Refresh or synchronize the `cluster-forge` parent application in Argo CD. The
parent renders only names present in `enabledApps`, so an entry under `apps`
alone does not create a child application.

The `aim-cluster-model-source-additional` application should appear. Its
automated sync policy then applies the source manifest.

Validate the result:

```bash
kubectl get application -n argocd \
  cluster-forge aim-cluster-model-source-additional

kubectl get aimclustermodelsource epyc-qwen3-8b-0-13-0 --watch
```

When discovery completes, locate the generated model:

```bash
kubectl get aimclustermodels \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.image,STATUS:.status.status
```

Open the AI Workbench AIM catalog and use its refresh action, or wait at least
30 seconds for its periodic refresh. The model can appear as unsupported when
the cluster lacks compatible hardware; that is expected for catalog-only
validation.

## Add more sources

Create one root-level manifest per source using a hardware-family filename:

```text
cpu-<model>-<version>.yaml
epyc-<model>-<version>.yaml
instinct-<model>-<version>.yaml
radeon-<model>-<version>.yaml
```

The configured Argo CD include expression discovers these files. Each manifest
can contain one or more exact image filters, but separate immutable sources
make ownership, replacement, and cleanup easier to understand.

After committing a new file, refresh the additional application if Argo CD has
not detected it automatically.

## Replace or remove a source

Do not narrow the filters of an existing source when the goal is to remove
catalog entries. AIM Engine keeps previously discovered models.

For deterministic replacement:

1. Commit the new, uniquely named source manifest.
2. Remove the old source manifest in the same change.
3. Keep `aim-cluster-model-source-additional` in `enabledApps`.
4. Synchronize the additional application with pruning enabled.
5. Confirm that Argo CD deleted the old `AIMClusterModelSource`.
6. Confirm that Kubernetes garbage-collected its owned models.

For removal without replacement, delete the source manifest and manually
synchronize the additional application with pruning enabled. Verify cleanup
before disabling the application:

```bash
kubectl get aimclustermodelsource <source-name>
kubectl get aimclustermodels
```

## Disable the additional catalog application

Use this order:

1. Remove every additional source manifest from Gitea.
2. Synchronize `aim-cluster-model-source-additional` with pruning enabled.
3. Verify that its `AIMClusterModelSource` resources and owned models are gone.
4. Remove `aim-cluster-model-source-additional` from `enabledApps`.
5. Synchronize the `cluster-forge` parent application with pruning enabled.

If the application is removed first, Argo CD deletes the child `Application`
but leaves its model sources running.

## Reconcile before a platform upgrade

Before upgrading to another Cluster Forge release:

1. Review the incoming packaged catalog.
2. Compare its image references with the additional source manifests.
3. Remove additional sources whose models are now in the packaged catalog.
4. Follow the manifest-first prune sequence above.
5. Upgrade only after the additional catalog contains no unintended
   duplicates.

This preserves the additional application as an inter-release mechanism rather
than a second permanent release catalog.

## Troubleshooting

### The additional application does not appear

Confirm that:

- `aim-cluster-model-source-additional` is in the existing `enabledApps` list;
- its definition is under `apps`;
- both changes were committed to `cluster-values/main`; and
- the `cluster-forge` parent application was refreshed or synchronized.

### The application disappeared but its model remains

The child application was removed before its resources were pruned. If the
source is no longer managed by Argo CD, recover by deleting it directly:

```bash
kubectl delete aimclustermodelsource <source-name>
```

Use direct deletion only for recovery. Kubernetes should garbage-collect the
models owned by that source.

### Removing a filter did not remove the model

This is the append-only discovery behavior. Delete and replace the source, or
remove its manifest and synchronize with pruning enabled.

### The source reports a registry or discovery error

Check:

- the image repository and tag;
- registry reachability;
- whether the image is public;
- the referenced image pull secret for a private registry; and
- AIM Engine controller logs in `aim-system`.

### The model exists in Kubernetes but not in AI Workbench

Confirm the `AIMClusterModel` still exists and inspect its status. Refresh the
AI Workbench catalog and allow at least 30 seconds for its periodic query.

## Scope boundary

This workflow controls additional catalog sources on one installed cluster.
The AIM team remains responsible for producing release model sources, and the
Platform release process remains responsible for incorporating approved
sources into the packaged catalog.
