# Adding Extra Components

The core stack is defined by `root/values.yaml`'s `enabledApps`/`apps` and
lives in this repo. Extra components — anything else a user wants installed
alongside it — go through a separate app-of-apps, `cluster-forge-extras`, and
never touch this repo.

## Why separate

Helm renders a chart all-or-nothing, so a malformed core `apps` entry would
break every core Application. `root/templates/cluster-forge-extras.yaml`
instead renders one static Application pointing at its own chart,
`root-extras/`. A broken extra component only breaks `root-extras`'s render —
core keeps reconciling.

## Enabling a component

Add an entry to `extraApps` in **`extra-apps-values.yaml`**, at the root of
the cluster-values overlay repo (kept separate from `values.yaml` so it
doesn't bloat as extras grow — path configurable via
`externalValues.extraAppsPath`). No cluster-forge or cluster-bloom change
needed:

```yaml
extraApps:
  my-component:
    project: default
    source:
      repoURL: https://github.com/some-org/some-chart.git
      path: charts/some-chart          # or `chart: name` for a repo/OCI chart
      targetRevision: v1.2.3
      helm:
        values: |
          replicaCount: 1
    destination:
      server: https://kubernetes.default.svc
      namespace: my-component
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
```

`extraApps.<name>` is a plain ArgoCD Application `spec:` block — `root-extras`
renders it as-is (`root-extras/templates/cluster-extra-apps.yaml`), no schema
of its own. Anything `Application.spec` supports (multi-source, Kustomize,
sync waves, ignoreDifferences, ...) works; see the [ArgoCD
docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/application.yaml).

`extraApps` is a map so the overlay deep-merges into it — Helm replaces lists
on merge but merges maps, which is also why core's `enabledApps` stays a list
that `gitea-init-job` must always write out in full.

## Upgrading an existing cluster

On a fresh install there is nothing to do: `gitea-init-job` seeds an empty
`extra-apps-values.yaml` into the cluster-values repo at bootstrap.

Clusters upgrading into the first release that ships `cluster-forge-extras`
predate that step, so the file will not exist. `cluster-forge-extras`
references it unconditionally and Helm fails hard on a missing `-f` target, so
create it in the cluster-values repo **before** bumping
`clusterForge.targetRevision`:

```yaml
# extra-apps-values.yaml
extraApps: {}
```

Bumping first is not harmful, just noisy: `cluster-forge-extras` sits in error
(`failed to load value file`) and `cluster-forge` reports Degraded until the
file lands. Nothing else is affected — core Applications keep reconciling, and
the extras app recovers on its own once the file exists, with no manual sync.
Note that migration runbooks gate on *all* apps being Synced/Healthy before
proceeding, so it is worth avoiding the red window.

## Shared context

`cluster-forge-extras` forwards core's resolved values into `root-extras`, so
extras see the same domain/registry/size as core:

- `global.domain`, `global.clusterSize`
- `ociRegistry.dockerHub`, `ociRegistry.ghcr`
- `clusterForge.repoUrl`, `clusterForge.targetRevision`
- `externalValues.repoUrl`, `externalValues.targetRevision` (your own
  cluster-values overlay repo)

Each `extraApps.<name>` block is passed through `tpl` in full, so any
`{{ .Values... }}` reference resolves anywhere inside it:

```yaml
extraApps:
  my-component:
    project: default
    source:
      repoURL: "{{ .Values.ociRegistry.dockerHub }}"
      chart: my-component-chart
      targetRevision: "1.0.0"
      helm:
        values: |
          ingress:
            host: "my-component.{{ .Values.global.domain }}"
    destination:
      server: https://kubernetes.default.svc
      namespace: my-component
    syncPolicy:
      automated: { prune: true, selfHeal: true }
```

### Escaping templates meant for the downstream chart

Because the whole block goes through `tpl`, `{{ ... }}` inside an inline
`helm.values` string is evaluated *here*, not passed through to the chart you
are installing. Anything using the downstream chart's own template variables —
Alertmanager/Prometheus rules, Grafana dashboards, log formats — has to be
escaped with backticks, or the render fails with `undefined variable`:

```yaml
        values: |
          text: "Instance {{ `{{ $labels.instance }}` }} is down"
```

Worth knowing that a single unescaped entry breaks the render of `root-extras`
as a whole, taking down *every* extra component, not just the offending one.
Core is unaffected either way.

### Quote version strings

Helm parses the overlay before `root-extras` ever sees it, so an unquoted
`targetRevision: 1.10` is read as the number `1.1` and silently installs the
wrong chart version. `2.0` becomes `2`, which the ArgoCD CRD then rejects
outright. Always quote:

```yaml
      targetRevision: "1.10"
```

## Using your own values file

For config too large for an inline `helm.values` block, keep it in a file in
the cluster-values overlay repo and add it as a second source via the
forwarded `externalValues` repo:

```yaml
extraApps:
  my-component:
    project: default
    sources:
      - repoURL: https://github.com/some-org/some-chart.git
        path: charts/some-chart
        targetRevision: v1.2.3
        helm:
          valueFiles:
            - $cluster-values/extra-apps/my-component/values.yaml
      - repoURL: "{{ .Values.externalValues.repoUrl }}"
        targetRevision: "{{ .Values.externalValues.targetRevision }}"
        ref: cluster-values
    destination:
      server: https://kubernetes.default.svc
      namespace: my-component
    syncPolicy:
      automated: { prune: true, selfHeal: true }
      syncOptions:
        - CreateNamespace=true
```

Then create `extra-apps/my-component/values.yaml` yourself, next to
`extra-apps-values.yaml` in the overlay repo.

## Shipping static manifests alongside a chart

Sometimes the upstream chart does not ship a resource the cluster needs. The
usual case is gateway wiring: routing a component through the cluster's Envoy
takes `HTTPRoute`, `EnvoyExtensionPolicy`, `Backend`, `BackendTLSPolicy` and
`ReferenceGrant` objects (or, for components going through the AI gateway
specifically, `AIGatewayRoute`/`AIServiceBackend` instead of `HTTPRoute`) — none
of which an application chart provides, because they describe *this* cluster's
gateway topology rather than the application. The exact resource set depends on
which gateway integration the component uses; see the
[`semantic-router`](../root-extras/blueprints/semantic-router/README.md)
blueprint for a worked example that uses the plain Gateway API + Envoy Gateway
extProc route rather than the AI gateway's own CRDs.

Point an additional source at a directory of plain YAML in the overlay repo.
ArgoCD combines the output of every source that sets `path`/`chart`, so the
chart's resources and your manifests end up in the same Application:

```yaml
extraApps:
  my-component:
    project: default
    sources:
      - repoURL: https://github.com/some-org/some-chart.git
        path: charts/some-chart
        targetRevision: v1.2.3
        helm:
          valueFiles:
            - $cluster-values/extra-apps/my-component/values.yaml
      # Static manifests, rendered by this same Application
      - repoURL: "{{ .Values.externalValues.repoUrl }}"
        targetRevision: "{{ .Values.externalValues.targetRevision }}"
        path: extra-apps/my-component/manifests
        directory:
          recurse: true
      - repoURL: "{{ .Values.externalValues.repoUrl }}"
        targetRevision: "{{ .Values.externalValues.targetRevision }}"
        ref: cluster-values
    destination:
      server: https://kubernetes.default.svc
      namespace: my-component
    syncPolicy:
      automated: { prune: true, selfHeal: true }
      syncOptions:
        - CreateNamespace=true
```

One Application, so one health rollup and one prune boundary: chart and
manifests sync together, and deleting a manifest file deletes its object.

The `ref: cluster-values` entry stays separate from the manifests entry even
though both point at the overlay repo. It exists only to resolve the
`$cluster-values` alias in `helm.valueFiles` and contributes no manifests of its
own.

**Create the directory yourself.** `extra-apps/my-component/manifests/`, next to
the values file from the previous section. It has to exist and hold at least one
file — otherwise ArgoCD fails the whole Application with `app path does not
exist`, taking the chart down with it. Git cannot track an empty directory, so
the directory and its first manifest arrive in the same commit as the source
entry referencing them.

**Keep the values file out of it.** A directory source applies every YAML it
finds, and a chart values file is not a valid Kubernetes object. Hence the
separate `manifests/` subdirectory rather than dropping manifests next to
`values.yaml`. If the directory has to hold files that should not be applied,
filter them with `directory.include` / `directory.exclude` globs.

**Not passed through `tpl`.** ArgoCD reads these files from the overlay repo
directly; they never go through `root-extras`, so `{{ .Values.global.domain }}`
will not resolve there. Hostnames and anything else derived from cluster context
have to be written out literally. Only the `extraApps` envelope is templated.

**Set `metadata.namespace` explicitly.** Objects land in `destination.namespace`
unless they say otherwise. A cross-namespace set — an `EnvoyExtensionPolicy` in
`envoy-gateway-system` targeting a Service in the component's own namespace —
needs a namespace on every object, and an AppProject that permits those
destinations.

**Ordering is not implied.** The chart and the manifests sync as one operation.
If an object depends on something the chart creates, annotate it
`argocd.argoproj.io/sync-wave: "1"`; if it uses a CRD that same chart installs,
also add `SkipDryRunOnMissingResource=true` to `syncOptions`. Neither is needed
for AI gateway resources — those CRDs come from core
(`sources/envoy-ai-gateway-crds/`).

## Starting points

Two kinds, depending on whether you are adding your own component or a
well-known one:

**`root-extras/values_addons.yaml`** — syntax templates. All three variants above
(inline `helm.values`, separate values file, added static manifests) with
placeholder values pointing at a fake repo. Shows the shape; deploys nothing.

**`root-extras/blueprints/<name>/`** — real, tested config for a named upstream
component, pre-filled except for the parts only you know. Each blueprint ships
an `extraApps.yaml` envelope, a `values.yaml`, a README covering prerequisites
and which fields to edit, and — where the upstream chart is missing resources
the cluster needs — a `manifests/` directory. The README carries `curl` commands
that pull them straight into a clone of your overlay repo; then edit the `TODO`s.
They are plain copies — once taken, they no longer track this repo, so a
blueprint change here will not alter a running cluster.

| Blueprint | What it deploys |
|---|---|
| [`semantic-router`](../root-extras/blueprints/semantic-router/README.md) | vLLM Semantic Router + dashboard on the shared `https` Gateway, wired in as an Envoy external processor so it picks the model each request routes to |

Note the blueprint's `values.yaml` and `manifests/` land in your overlay repo and
are read by ArgoCD directly, so unlike the `extraApps` block they are **not**
passed through `tpl` — `{{ .Values.global.domain }}` will not resolve in either.
Anything that has to derive from forwarded context belongs in the envelope's
inline `helm.values` instead; in a manifest it has to be written out literally
(see [Shipping static manifests alongside a chart](#shipping-static-manifests-alongside-a-chart)).

## Verifying locally

```bash
helm template root-extras root-extras/ \
  -f root-extras/values.yaml \
  -f /path/to/your-overlay.yaml
```
