*************
* AIWB STACK
*************

1. Deploy AIWB

```bash
export KUBECONFIG=/home/irodrigu/cluster-forge/docs/aiwb_on_openshift/kubeconfig-test.yaml
export CLUSTER_FORGE_DIR=".tmp/cf"

curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_openshift/install_base.sh | bash
```

---

2. Expected output

```bash
✅ AIWB application is ready

💡 Verification commands:
   kubectl get pods -n keycloak
   kubectl get pods -n aiwb
   kubectl get pods -n kaiwo-system
   kubectl get pods -n keda
   kubectl get pods -n otel-lgtm-stack
   kubectl get pods -n cnpg-system
   kubectl get pods -n amd-gpu-operator
   kubectl get cluster --all-namespaces

💡 Access:
   Gateway IP: 192.168.127.240:8080
   AIWB UI: https://aiwbui.150.136.93.180.nip.io
   AIWB API: https://aiwbapi.150.136.93.180.nip.io
   Keycloak: https://kc.150.136.93.180.nip.io

   Ensure DNS points aiwbui.150.136.93.180.nip.io, aiwbapi.150.136.93.180.nip.io, and kc.150.136.93.180.nip.io to 192.168.127.240

💡 Keycloak Admin Credentials:
   Username: silogen-admin
   Password: placeholder
   Admin Console: http://150.136.93.180.nip.io:8080/admin

💡 AIWB User Login:
   Username: devuser@150.136.93.180.nip.io
   Password: placeholder

📊 Observability (Grafana, Prometheus, Loki, Tempo):
   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000
   Access Grafana at: http://localhost:3000
   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090
   Access Prometheus at: http://localhost:9090

ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md
```
