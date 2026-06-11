*************
* TEST AIWB
*************

1. Create rancher with:

```bash
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/create_rke.sh | sudo bash
```

---

2. Get kubeconfig (put it into wsl path /home/irodrigu/cluster-forge/docs/aiwb_on_rke/kubeconfig-test.yaml) from the OCI host using

```bash
sudo cat /root/.kube/config
```

---

3. Tunnel from Windows (Run as admin powershell) to use kubeconfig from freelens:

```bash
ssh -o "ProxyCommand ssh -i C:\Users\irodrigu\.ssh\oci-clusters -W %h:%p ubuntu@129.153.146.116" ` -i C:\Users\irodrigu\.ssh\oci-clusters ` -L 18445:localhost:6443 ` ubuntu@10.0.255.107
```

Then use this block in kubeconfig then:

```yaml
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:18445
```

---

4. Tunnel from wsl to work from localhost the scripts

```bash
ssh -J ubuntu@129.153.146.116 -L 18446:10.0.255.107:6443 -p 22 ubuntu@10.0.255.107
```

Then use this block in kubeconfig then:

```yaml
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:18446
```

Then, before running scripts setup variable

---

5. Deploy script to install AIWB

```bash
rm -rf /tmp/cluster-forge/

export KUBECONFIG=/home/irodrigu/cluster-forge/docs/aiwb_on_rke/kubeconfig-test.yaml
export CLUSTER_FORGE_DIR=".tmp/cf" && mkdir -p $CLUSTER_FORGE_DIR
./install_base.sh 129.213.82.159.nip.io
```

6. Expected output

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
