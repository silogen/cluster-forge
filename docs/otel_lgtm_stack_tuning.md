# Tuning the otel-lgtm-stack per cluster

This chart runs the full **LGTM** observability stack (Grafana + Loki + Prometheus + Tempo + Pyroscope)
inside a single `lgtm` pod, plus a set of OpenTelemetry **collectors**. On small / under-specced clusters the `lgtm` pod
(and some collectors) can hit **OOM**, and the Prometheus / Loki data volumes can fill up.

This refactor exposes the knobs needed to deal with that **from
`cluster-values.yaml` in gitea** — no template edits and no image rebuild.

---

## TL;DR — what you can tune, and how

| What you want to change            | Override path                                   | How much to write            |
| ---------------------------------- | ----------------------------------------------- | ---------------------------- |
| Go memory soft-limit (all procs)   | `lgtm.extraEnv.GOMEMLIMIT`                       | ✅ one line                  |
| Prometheus retention (time + size) | `lgtm.extraEnv.PROMETHEUS_EXTRA_ARGS`           | ✅ one line (keep `>-`!)     |
| Grafana auth                       | `lgtm.extraEnv.GF_AUTH_*`                        | ✅ one line each             |
| Any other lgtm env var             | `lgtm.extraEnv.<NAME>`                           | ✅ one line                  |
| Global scrape interval             | `collectors.scrapeInterval`                      | ✅ one line                  |
| Per-job scrape interval            | `collectors.scrapeIntervalOverrides.<job>`       | ✅ one line                  |
| Collector memory guard             | `collectors.memoryLimiter.*`                     | ✅ one line each             |
| Collector CPU / memory resources   | `collectors.resources.*`                         | ✅ partial (only what you set)|
| **Apiserver metric filtering**     | `collectors.metricFilters.*`                     | ✅ one line                  |
| **Loki retention / any Loki cfg**  | `lgtm.configOverrides.lokiConfig`                | ❌ **paste whole ~70-line blob** |
| **OpenTelemetry collector config** | `lgtm.configOverrides.otelcolConfig`             | ❌ **paste whole ~100-line blob** |

**The one rule to remember:**
- Rows marked ✅ are **partial overrides** — write only the key you want to change; everything else keeps the chart default.
- Rows marked ❌ are **whole-blob overrides** — the value is a single YAML string, and Helm cannot merge inside a string.
To change one line you must paste the entire blob and edit that one line.

> Why the split? Frequently-tuned values (retention, memory, scrape rate) are
> exposed as one-liners. The two big blobs stay whole on purpose: they are a
> complete **escape hatch** for anything not otherwise exposed, and Helm can't
> safely deep-merge a config-file string.

---

## Where do I put these?

In this cluster's `cluster-values.yaml` (in gitea), under the app entry.
Only list the keys you actually want to change. (New to how these overrides
flow? See [`values_inheritance_pattern.md`](./values_inheritance_pattern.md).)

```yaml
apps:
  otel-lgtm-stack:
    valuesObject:
      lgtm:
        extraEnv:
          GOMEMLIMIT: "4GiB"
          PROMETHEUS_EXTRA_ARGS: >-
            --storage.tsdb.retention.time=72h
            --storage.tsdb.retention.size=20GB
      collectors:
        scrapeInterval: 60s
        scrapeIntervalOverrides:
          kubernetes-pods-slow: 10m
        memoryLimiter:
          limitPercentage: 75
```

ArgoCD picks up the gitea change, re-renders the chart, and **the lgtm pod
restarts automatically** (env changes the pod template; blob changes flip a
`checksum/*-config` annotation). No manual restart needed.

---

## The tricky ones — copy-paste carefully

### 1. `PROMETHEUS_EXTRA_ARGS` — keep the `>-` folded style

Prometheus retention is a **command-line flag** (there is no config-file field
for it), so it lives in `extraEnv`. It must be written in YAML **folded style
(`>-`)** so multiple flags render as a single space-separated line:

```yaml
lgtm:
  extraEnv:
    PROMETHEUS_EXTRA_ARGS: >-
      --storage.tsdb.retention.time=72h
      --storage.tsdb.retention.size=20GB
```

⚠️ **Do NOT use `|` (literal block).** With `|` the newlines are kept, and the
image's startup script (`read -ra ... <<<"$PROMETHEUS_EXTRA_ARGS"`) stops at the
first newline — silently dropping every flag after the first (e.g. retention
size would be lost).

### 2. `lokiConfig` — whole blob, change one line

Loki retention (and everything else about Loki) is set **in-file**. To change
retention you copy the entire `lokiConfig` blob from
[`values.yaml`](../sources/otel-lgtm-stack/v1.0.8/values.yaml) into
`cluster-values.yaml` and edit only `limits_config.retention_period`:

```yaml
lgtm:
  configOverrides:
    lokiConfig: |
      # ... paste ALL lines from values.yaml lokiConfig ...
      limits_config:
        retention_period: 72h   # ← change only this (default 168h)
      # ... rest unchanged ...
```

The same applies to `otelcolConfig` (the OpenTelemetry Collector config).

---

## Metric filtering, and re-enabling dropped metrics

### What is dropped, and why

The `kubernetes-apiservers` scrape job is the dominant cost in this stack.
Measured on int-test (3 control planes, 2026-09-16):

| | |
| --- | --- |
| samples per scrape, whole cluster | 466,000 |
| ...from `kubernetes-apiservers` | **397,000 (85%)** |
| total active series | 470,261 |
| ...that are apiserver histogram buckets | **333,661 (71%)** |

Nothing this chart ships queries them: the three bundled dashboards reference no
`apiserver_*` or `etcd_*` metric, and the chart ships no alerting rules.

Filtering is applied as `metric_relabel_configs` on the collector's prometheus
receiver, i.e. **at scrape time**. That shrinks both the
`otel-collector-metrics-k8s` working set (the component that has been OOMKilled
at its 8Gi limit) and the Prometheus TSDB behind it.

| Profile | What it does | Series cut |
| --- | --- | --- |
| `full` | Nothing is dropped. | 0% |
| `standard` *(default)* | Drops `apiserver_request_sli_duration_seconds*`, `apiserver_request_body_size_bytes*`, `apiserver_response_sizes*` and the three `apiserver_watch_*` families. Thins `apiserver_request_duration_seconds` and `etcd_request_duration_seconds` from 24 histogram boundaries to the six in `keepBuckets`. | ~60% |
| `minimal` | `standard`, plus every remaining histogram bucket on the job. | ~71% |

Under `standard`, `histogram_quantile()` still works on both latency
histograms — coarsely, and `le="1"` (the boundary the Kubernetes API SLI is
defined on) is retained. Under `minimal` there are no quantiles at all;
`_count` / `_sum` survive, so request rate, error ratio and *mean* latency keep
working.

### ⚠️ Dropped samples are never stored

This is the one thing to understand before tuning it. A `metric_relabel_configs`
drop happens **before the sample is written**, so re-enabling a metric restores
it **from that moment forward — it cannot recover history.**

- Debugging a *live* problem: fine. Flip the switch, data flows within one
  scrape interval, watch it happen.
- Post-mortem of something that already ended: those buckets are gone. What
  survives is `_count` / `_sum`, so history still shows *that* latency was
  elevated, just not the shape of the distribution.

### How to re-enable (the one-line switch)

In this cluster's `cluster-values.yaml` in gitea:

```yaml
apps:
  otel-lgtm-stack:
    valuesObject:
      collectors:
        metricFilters:
          keepAllBuckets: true    # keep every apiserver/etcd histogram bucket
```

or, to turn filtering off entirely:

```yaml
        metricFilters:
          profile: full
```

ArgoCD picks up the change, the OpenTelemetry operator rolls the
`otel-collector-metrics-k8s` deployment, and the metrics reappear within one
scrape interval. Roughly two minutes end to end. The restart is cheap: the
prometheus receiver is stateless and counter values come from the targets, so
nothing resets.

**Do not `kubectl edit` the OpenTelemetryCollector CR to do this.** ArgoCD
selfHeal reverts it within minutes. Use the overlay, or pause auto-sync first if
you genuinely need a ten-minute look.

### Two gotchas

- **Queries spanning the change show gaps.** Old blocks have no buckets, new
  ones do. `histogram_quantile()` over that range returns a partial result
  rather than an error — which is the confusing kind of wrong. Expect the
  boundary to wash out after one retention window (7 days by default).
- **`keepBuckets` is a list, so an override replaces it wholesale** rather than
  merging — that is deliberate (you are choosing your own boundaries), but it
  means you must write the full list, not just the extra values you want. The
  values must also match the exposition format exactly: `"1"`, not `"1.0"`.

---

## Cluster size tiers

`values_small.yaml`, `values_medium.yaml` and `values_large.yaml` in `root/`.
**small and medium are identical for this app** and match the chart defaults;
`values_large.yaml` raises exactly three values.

### Why the tiers split on control planes, not nodes

Measured across all seven multi-node clusters (2026-09-15/16, EAI-8713), only
one thing structurally drives the cost of this stack: **control-plane count**.
A 1-CP cluster produces ~137k apiserver samples and ~237k series; a 3-CP cluster
produces ~300-390k and ~400-490k. Node count barely matters, because the
`kubernetes-apiservers` job scrapes every API server and is 85% of all samples.

Every other container -- both daemonsets, the three small collectors,
kube-state-metrics, node-exporter -- measured **flat** across all seven clusters
regardless of size. They inherit the chart default at every tier. Making them
differ would invent variation the measurements do not show.

So in practice: single-node cluster -> `small` or `medium`; multi-node
(3 control planes) -> `large`.

### What differs

| | small = medium | large |
| --- | --- | --- |
| `lgtm.resources.limits.memory` | 8Gi | **16Gi** |
| `lgtm.resources.requests` | 500m / 2Gi | **750m / 4Gi** |
| `collectors.resources.metrics.limits.memory` | 8Gi | **16Gi** |
| `collectors.resources.metrics.requests` | 750m / 2Gi | **750m / 4Gi** |
| `lgtm.storage.loki` | 50Gi | **100Gi** |

### The rules behind the numbers

- **Memory request = 25% of the limit.** The limit is the protection boundary;
  the request is the scheduling reservation. They answer different questions.
- **CPU request is set close to measured usage.** Requests are now the only
  lever the scheduler has, so they need to be real.
- **No CPU limits anywhere.** CPU is compressible -- contention degrades a
  workload, it does not kill it -- so a CPU limit mostly buys throttling. It was
  costing us: chrony-exporter was throttled 18% of periods at its 0.1 CPU limit,
  logs-collector 4% at 1 CPU, both for workloads using milliCPU. Memory limits
  stay, because memory is *not* compressible and exceeding one is an OOMKill.
- **`collectors.resources.metrics` keeps a large memory limit deliberately.**
  That collector runs the apiserver scrape and has been OOMKilled twice
  (epycenv 2026-09-04, workload-dev 2026-09-11) from a 1-2 GiB steady state. The
  spike is not yet characterised, so the limit is headroom, not a fitted value.
  Note its `memory_limiter` (80% / 5s) did **not** engage before either kill --
  so if you are tuning this, `collectors.memoryLimiter.checkInterval` is a more
  promising lever than the limit itself.

### Do not pin resources in `root/values.yaml`

Values there win over the chart defaults for every tier, which silently
neutralises the size files. `root/values.yaml` sets only `metricFilters` and
storage for this app; resources live in the chart and the three size files.

---

## Quick reference: current defaults

| Key                                        | Default |
| ------------------------------------------ | ------- |
| `lgtm.extraEnv.GOMEMLIMIT`                 | `6GiB`  |
| Prometheus `retention.time`                | `168h`  |
| Prometheus `retention.size`                | `40GB`  |
| `collectors.scrapeInterval`                | `30s`   |
| `collectors.memoryLimiter.limitPercentage` | `80`    |
| `collectors.memoryLimiter.spikeLimitPercentage` | `25` |
| Loki `retention_period`                    | `168h`  |
| `collectors.metricFilters.profile`         | `standard` |
| `collectors.metricFilters.keepAllBuckets`  | `false` |

(See [`values.yaml`](../sources/otel-lgtm-stack/v1.0.8/values.yaml) for the
full, authoritative list and inline comments.)

---

## Notes / out of scope

- **`GOMEMLIMIT` is a shared safety line, not per-process budgeting.** It is set
  once as a pod env var and inherited *identically* by every Go sub-process in
  the `lgtm` container — Grafana, Loki, Prometheus, Tempo, Pyroscope and the
  bundled OpenTelemetry collector each get the *same* value (e.g. each thinks it
  may use `6GiB`), rather than sharing one budget between them. It is a soft GC
  target: as a process approaches it, Go runs GC more
  aggressively; it does **not** kill anything (the kernel does that at the
  container memory limit). True per-process memory budgeting would require
  modifying the upstream `grafana/otel-lgtm` image and is intentionally **out of
  scope**.
- **Collectors already have a `memory_limiter` processor** (now tunable via
  `collectors.memoryLimiter.*`). It applies **backpressure** — refusing incoming
  data as memory approaches the limit — which is the primary OOM guard for
  collectors. That's why no `GOMEMLIMIT` is set on the collectors.
- **Log filtering** (namespace / severity filters on the logs pipeline) is still
  **not** part of this chart — tracked separately. Metric filtering for the
  `kubernetes-apiservers` job now exists: see *Re-enabling dropped metrics* above.
