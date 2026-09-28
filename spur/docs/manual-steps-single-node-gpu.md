# Manual steps of a single-node GPU test

This page lists the commands that a test of the `demo` profile with a GPU AIM
needed, and that `README.md` and the `justfile` do not give. Use it as a
checklist for the next test round. Remove a step when a recipe or the README
covers it.

The test ran on 2026-09-28 on one DigitalOcean node with eight MI325X GPUs
(`ml-ai-ubuntu-gpu-mi325x8-06`, Ubuntu 24.04). Spur was a build of main
(0.13.0), and `spur-aims` was a build of the branch `EAI-8560-byok`.

Result: `spur-aims install demo`, `just smoke-ui` and `just smoke-gpu` passed.
`amd/Llama-3.1-8B-Instruct-FP8-KV` answered on one GPU.

## 1. Remove an old Spur installation

Do this only when an earlier Spur or k0s installation is on the node. Make a
backup first.

```bash
mkdir -p /root/old-spur-backup
iptables-save > /root/old-spur-backup/iptables.before
tar czf /root/old-spur-backup/old-spur.tgz /etc/spur
pkill spurd; pkill spurctld
rm -rf /etc/spur /var/spool/spur /usr/libexec/k0s /opt/cni /opt/containerd /etc/cni /root/.kube
iptables-save | grep -vi kube | iptables-restore
ip6tables-save | grep -vi kube | ip6tables-restore
ipset list -n | grep -i kube | xargs -r -n1 ipset destroy
```

When `/var/lib/k0s` is still there, run `sudo spur k8s down --reset` before
this step. See [Set up one node](spur-node-setup.md#9-take-it-down-again).

## 2. Build Spur

In a checkout of the spur repository:

```bash
cargo build --release --bin spurctld --bin spurd --bin spur
```

The binaries go to the cargo target directory. When `CARGO_TARGET_DIR` is set,
they are not in `target/release`.

## 3. Copy the binaries to the node

`just node-install` copies `spur-aims` only. Copy the Spur binaries too:

```bash
scp -C <target>/release/{spurctld,spurd,spur} spur/spur-aims/spur-aims root@<node>:/tmp/
ssh root@<node> 'install -m755 /tmp/{spurctld,spurd,spur,spur-aims} /usr/local/bin/'
```

## 4. Set the host firewall

The firewall step is different for each image.

- **OCI (Kaytoo) VMs.** The image rejects everything but SSH. Open the VM
  subnet and the k0s networks on every node:

  ```bash
  for cidr in 10.0.255.0/24 10.244.0.0/16 10.96.0.0/12 10.42.0.0/16 10.43.0.0/16 10.44.0.0/16; do
    sudo iptables -I INPUT 1 -s $cidr -j ACCEPT
  done
  ```

- **A node with a public IP and an INPUT policy of ACCEPT**, such as the
  DigitalOcean node. With `[auth] plugin = "none"`, any host that reaches the
  Spur ports can run work as root. Close the Spur ports to the internet:

  ```bash
  for p in 6817 6818 6820 6821; do
    iptables -A INPUT -p tcp --dport $p -j DROP
    for s in 127.0.0.0/8 10.0.0.0/8; do iptables -I INPUT 1 -p tcp -s $s --dport $p -j ACCEPT; done
  done
  ip6tables -A INPUT -p tcp -m multiport --dports 6817,6818,6820,6821 ! -s ::1 -j DROP
  ```

  These rules do not close the other ports. See [Open ports](#open-ports).

## 5. Write /etc/spur/spur.conf

Use the file of [Set up one node, step 3](spur-node-setup.md#3-write-etcspurspurconf).
Set `nodes` and `control_plane_node` to the output of `hostname`. On a node
with a large root disk, `local_path_dir = "/var/lib/local-path-provisioner"`
is sufficient, and step 5 of that page is not necessary.

## 6. Start the daemons

```bash
sh -c 'setsid nohup spurctld -f /etc/spur/spur.conf > /var/log/spurctld.log 2>&1 < /dev/null &'
sleep 8
sh -c 'setsid nohup spurd --controller http://localhost:6817 --address <private ip> > /var/log/spurd.log 2>&1 < /dev/null &'
```

## 7. Bring up k0s and check it

```bash
spur nodes --controller http://localhost:6817
spur k8s install-k0s
spur k8s up --controller http://localhost:6817
spur k8s status
k0s kubectl get nodes
k0s kubectl get sc
```

`spur admin raft status` does not exist in every Spur build. Use `spur nodes`.

## 8. Use spur-aims, not spur aims

Spur main has no plugin mechanism (ROCm/spur#925 is not merged). Call the
binary directly: `spur-aims install ...`, `spur-aims status`.

```bash
spur-aims install demo --var domain=<public ip>.nip.io \
  --var gatewayServiceType=ClusterIP --var gatewayExternalIP=<public ip>
```

## 9. Label a node that has MI325X virtual functions

A DigitalOcean GPU node shows each MI325X as a virtual function, PCI ID
`74b9`. The NFD rule of the GPU operator labels such a node
`feature.node.kubernetes.io/amd-vgpu=true`, but the DeviceConfig selects
`feature.node.kubernetes.io/amd-gpu=true` only. Without this label the node
has no device plugin and no `amd.com/gpu`:

```bash
k0s kubectl label node <node> feature.node.kubernetes.io/amd-gpu=true
k0s kubectl get node <node> -o jsonpath='{.status.allocatable.amd\.com/gpu}'
```

cluster-bloom sets the same label with its node-annotator CronJob, so the
ArgoCD path does not need this step.

## 10. Reach the cluster from a network with Zscaler

Zscaler resets the connections to port 6443 and blocks `nip.io` names. Use SSH
for both:

```bash
ssh root@<node> 'spur k8s kubeconfig --admin' > /tmp/node.kubeconfig
ssh -f -N -L 16443:127.0.0.1:6443 root@<node>
sed 's#https://<public ip>:6443#https://127.0.0.1:16443#' /tmp/node.kubeconfig > /tmp/node-tunnel.kubeconfig
ssh -f -N -D 11080 root@<node>
export KUBECONFIG=/tmp/node-tunnel.kubeconfig
export ALL_PROXY=socks5h://127.0.0.1:11080   # curl only; kubectl uses the tunnel
```

## 11. Run the smoke tests on a demo cluster

`just smoke-gpu` uses the namespace `aims-test`. On a `demo` cluster, routing
is on, and the test must run in `workbench`:

```bash
just smoke-ui
NAMESPACE=workbench KEEP=1 AIM_TIMEOUT=40m just smoke-gpu
```

The first pull of the GPU model image takes minutes, so give a longer
`AIM_TIMEOUT`. `KEEP=1` keeps the model for a test in the browser.

## Open ports

After the test, these ports answered on the public address of the node:

| Port | Process | Access |
|---|---|---|
| 22 | sshd | Key login |
| 443 | Envoy gateway | The AIWB UI and API need a login. The model routes on `workloads.<domain>` need a Dex token. |
| 6443 | kube-apiserver | Client certificate |
| 10250 | kubelet | Client certificate |
| 179 | kube-router BGP | Configured peers only |
| 2380 | kine | Metrics only |
| 8080, 20244 | kube-router | Health and metrics |
| 10249, 10256 | kube-proxy | Metrics and health |

Close all ports except 22 and 443 with a cloud firewall. Every user who can
log in to Dex can call the models, so limit 443 to known addresses when that
is too wide.
