# Cluster-Forge scripts

Supported install/operator helpers. Backup and restore **examples** live in [`utils/`](utils/README.md) and are not covered here.

- `ai-gateway-webhook-health.sh` — Probe (and heal) the envoy-ai-gateway pod mutating webhook when `clientConfig.caBundle` drifts from the controller TLS secret. Mainline clusters prevent drift via cert-manager (`root/values.yaml`); use this script for legacy clusters, post-cutover recovery, and operator runbooks. Healing syncs caBundle, restarts the controller, rolls https and ai-gateway Envoy data-plane Deployments, and verifies Gateway `Programmed=True`. Used by OpenShift `docs/openshift/install.sh`; operators may run it on RKE2/mainline clusters. Override chart names via environment variables (`WEBHOOK_NAME`, `SECRET_NAME`, and related vars; see `--help`). Use `--probe-only` for platform gate checks (no heal).
- [`platform-gates/`](platform-gates/README.md) — Post-handoff platform checks (Gateway programmed, webhook probe, HTTPS AIWB UI) with a mandatory report artifact for Kaytoo validation and future shared-cluster CI.
