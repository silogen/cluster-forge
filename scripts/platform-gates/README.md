# Platform gates

Post-handoff checks for a bloomed cluster: Envoy Gateway programming, AI Gateway
admission webhook trust, and external HTTPS to AI Workbench UI.

Run after bloom (and after any readiness gate such as AIWB API rollout). These
assertions catch regressions that internal API health checks can miss — for
example mutating webhook CA drift blocking Envoy HTTPS data-plane pods while
in-cluster `/v1/health` still returns OK. Webhook TLS is normally issued by
cert-manager on mainline clusters; the webhook gate probes admission and does
not heal during CI.

## Usage

On the cluster head (kubeconfig at `/root/.kube/config` after bloom):

```bash
export PLATFORM_DOMAIN=<cluster-domain>   # bloom apex DOMAIN (see root/values.yaml)
export CLUSTERFORGE_RELEASE=v2.2.2        # optional metadata for the report
sudo KUBECONFIG=/root/.kube/config \
  scripts/platform-gates/run-all.sh \
  --report ~/platform-gates-report.txt
```

From a dev VM with SSH access to the bloom head, stage this repo’s `scripts/platform-gates/`
on the host and run the same `run-all.sh` command with `PLATFORM_DOMAIN` set to the
cluster’s apex domain.

## Gates (in order)

| Gate | Script | Pass criteria |
|------|--------|---------------|
| Gateway programmed | `gateway-programmed.sh` | Gateway `https` (and `ai-gateway` when present) has `Programmed=True` |
| AI Gateway webhook | `ai-gateway-webhook.sh` | Probe pod CREATE accepted (`--probe-only`; no heal). Heal path (operators) also rolls https + ai-gateway data planes and verifies `Programmed=True`. |
| HTTPS AIWB UI | `https-aiwb-ui.sh` | `curl -sfI` to `https://aiwbui.<domain>/` via gateway LB IP (`--resolve`; avoids hairpin NAT failures from the head node) |

## Report artifact

`run-all.sh` always writes `~/platform-gates-report.txt` (override with
`--report` or `PLATFORM_GATES_REPORT`). The file is the merge/review artifact:
paste the full contents into a PR comment. On failure the report includes the
last lines of `~/bloom-cli.log` when that file exists on the host.

## Environment

| Variable | Purpose |
|----------|---------|
| `PLATFORM_DOMAIN` | Cluster apex domain from bloom config (required for HTTPS gate) |
| `CLUSTERFORGE_RELEASE` | Recorded in report metadata only |
| `PLATFORM_GATES_HOST` | Hostname recorded in report metadata |
| `PLATFORM_GATES_REPORT` | Report path (default `~/platform-gates-report.txt`) |
| `KUBECONFIG` | kubectl config (use `/root/.kube/config` on bloom head) |

Webhook gate env vars are documented in `../ai-gateway-webhook-health.sh`.
