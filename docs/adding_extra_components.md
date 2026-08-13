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

## Example

`root-extras/values_addons.yaml` has copy-paste `extraApps` blocks (inline and
values-file variants) with placeholder values — not real components. Copy
one into your overlay's `extra-apps-values.yaml`, rename it, point
`source`/`sources` at your own chart.

## Verifying locally

```bash
helm template root-extras root-extras/ \
  -f root-extras/values.yaml \
  -f /path/to/your-overlay.yaml
```
