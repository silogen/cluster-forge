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
- **Metric / log filtering** (dropping high-cardinality series, namespace/
  severity log filters) is **not** part of this change — it's tracked separately.
