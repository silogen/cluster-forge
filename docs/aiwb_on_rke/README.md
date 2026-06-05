# AIWB STACK DEPLOYMENT

Here are the details needed to decploy an AIWB stack only considering that end user is able to get access to a GPU host using Ubuntu 22.04,24.04 and AMDGPU driver already installed.

1. Create a vanilla RKE rancher running on the host

```bash
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/create_rke.sh | sudo bash
```

---

2. Get kubeconfig

```bash
# bash
sudo cat /root/.kube/config
```

---

3. Setup ssh tunnel (Optional)

Consider to replace values for the following in advance scripts<br>

**HOST_IP_PRIVATE**<br>
**HOST_IP_PUBLIC**<br>
**HOST_JUMP_SERVER**<br>


3.1 Create SSH tunnel

```powershell
# powershell
ssh -o "ProxyCommand ssh -i C:\Users\irodrigu\.ssh\oci-clusters -W %h:%p ubuntu@HOST_JUMP_SERVER" ` -i MY-PRIVATE-KEY ` -L 18445:localhost:6443 ` ubuntu@HOST_IP_PRIVATE
```

```bash
# bash
ssh -J ubuntu@HOST_JUMP_SERVER -L 18445:HOST_IP_PRIVATE:6443 -p 22 ubuntu@HOST_IP_PRIVATE
```


3.2 Setup K8 config for remote access


Then use this block in kubeconfig taking form step 2 and replace the cluster block for:

```yaml
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:18445
```

---

4. Finally deploy the AIWB stack

```bash
# bash
# Prepare minimal variables
export KUBECONFIG=(PATH-TO-KUBECONFIG-FROM-STEP-2)
export CLUSTER_FORGE_DIR=".tmp/cf"
mkdir -p $CLUSTER_FORGE_DIR
export PUBLIC_IP_DOMAIN=$(curl -s ifconfig.me).nip.io

# Deploy AIWB 
curl -fsSL https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/install_base.sh | sudo bash -s -- ${PUBLIC_IP_DOMAIN}
```

```powershell
# powershell
# Prepare minimal variables
$env:KUBECONFIG = "<PATH-TO-KUBECONFIG>"
$env:CLUSTER_FORGE_DIR = ".tmp/cf"
New-Item -ItemType Directory -Force -Path $env:CLUSTER_FORGE_DIR | Out-Null
$PUBLIC_IP_DOMAIN = "$(Invoke-RestMethod ifconfig.me).nip.io"

# Deploy AIWB (requires bash available via WSL or Git Bash)
$script = (Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/test-aiwb/docs/aiwb_on_rke/install_base.sh").Content
$script | bash -s -- $PUBLIC_IP_DOMAIN
```

---

5. Expected output

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
   AIWB UI: https://aiwbui.PUBLIC_IP_DOMAIN.nip.io
   AIWB API: https://aiwbapi.PUBLIC_IP_DOMAIN.nip.io
   Keycloak: https://kc.PUBLIC_IP_DOMAIN.nip.io

   Ensure DNS points aiwbui.PUBLIC_IP_DOMAIN.nip.io, aiwbapi.PUBLIC_IP_DOMAIN.nip.io, and kc.PUBLIC_IP_DOMAIN.nip.io to 192.168.127.240

💡 Keycloak Admin Credentials:
   Username: silogen-admin
   Password: placeholder
   Admin Console: http://PUBLIC_IP_DOMAIN.nip.io:8080/admin

💡 AIWB User Login:
   Username: devuser@PUBLIC_IP_DOMAIN.nip.io
   Password: placeholder

📊 Observability (Grafana, Prometheus, Loki, Tempo):
   Grafana: kubectl port-forward -n otel-lgtm-stack svc/lgtm 3000:3000
   Access Grafana at: http://localhost:3000
   Prometheus: kubectl port-forward -n otel-lgtm-stack svc/lgtm 9090:9090
   Access Prometheus at: http://localhost:9090

ℹ️  To install the CPU-only dummy model for local testing, see internal/DEV_INSTRUCTIONS.md
```
