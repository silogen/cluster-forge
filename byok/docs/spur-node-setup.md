# Set up one node for byok with Spur

Every step of a single-node install, from a node that runs nothing to a
profile that serves a model. This is the path the GPU test of
`useocpm2m-silogen-014` took, step by step. A multi-node cluster adds only the
peer list of step 3 and a `spurd` on every node.

The node needs no helm, kubectl, yq, jq or git: the Go build of `spur-silo`
holds the charts. It does need to reach the container registries.

## 1. Build the binaries

Spur, from a checkout of the spur repository:

```bash
cargo build --release --bin spurctld --bin spurd --bin spur
```

`spur-silo`, from a checkout of cluster-forge. `make assets` needs helm and the
network once, `make build` needs neither:

```bash
make -C byok/spur-silo assets build REF=<branch-or-tag>
```

## 2. Copy them to the node

```bash
scp -C target/release/{spurctld,spurd,spur} ubuntu@<node>:/tmp/
scp -C byok/spur-silo/spur-silo ubuntu@<node>:/tmp/
ssh ubuntu@<node> 'sudo install -m755 /tmp/{spurctld,spurd,spur,spur-silo} /usr/local/bin/'
```

Check the size of every file on the node against the source. A copy that stops
in the middle gives a binary that starts and prints nothing, with no error.

`spur silo ...` works when the `spur` build holds the plugin mechanism.
`spur-silo ...` works with any build.

## 3. Write /etc/spur/spur.conf

```toml
cluster_name = "gpu1"

[controller]
listen_addr = "[::]:6817"
rest_addr = "[::]:6820"
raft_listen_addr = "[::]:6821"
node_id = 1
peers = ["<node private ip>:6821"]

[cluster]
enabled = true
allow_admin_kubeconfig = true

[[partitions]]
name = "compute"
default = true
state = "UP"
nodes = "<hostname>"
max_time = "1-00:00:00"
default_time = "0:10:00"
min_nodes = 1
```

Three things that cost time if they are missing:

- `cluster_name` is mandatory and sits at the top level. Without it `spurctld`
  exits with `missing field cluster_name`.
- `[cluster] enabled = true` must be there **before** `spurctld` starts. The
  reconcile loop only runs when it is set, and `spur k8s up` then stays in
  `provisioning` for ever.
- `allow_admin_kubeconfig = true` lets `spur-silo` ask Spur for the admin
  kubeconfig. Without it the plugin falls back to `sudo -n k0s kubeconfig
  admin`, which works on a control-plane node only.

## 4. Open the k0s networks in the host firewall

An Ubuntu image that rejects everything but SSH also rejects the pod and
service networks:

```bash
sudo iptables -I INPUT 1 -s 10.244.0.0/16 -j ACCEPT   # k0s pods, kube-router
sudo iptables -I INPUT 1 -s 10.96.0.0/12 -j ACCEPT    # k0s services
```

Check with `sudo iptables -L INPUT -n | head`. A node whose INPUT chain ends in
`ACCEPT` needs nothing. Nothing in any log names this as the cause; the symptom
is a cluster that never becomes ready.

## 5. Give k0s a data directory with room

One AIM image with its cache is larger than a normal root disk. Put
`/var/lib/k0s` on the big disk **before** `spur k8s up`:

```bash
sudo mkdir -p /mnt/disk0/k0s /var/lib/k0s
sudo mount --bind /mnt/disk0/k0s /var/lib/k0s
```

## 6. Start the daemons

```bash
sudo sh -c 'setsid nohup spurctld -f /etc/spur/spur.conf > /var/log/spurctld.log 2>&1 < /dev/null &'
sleep 8
sudo sh -c 'setsid nohup spurd --controller http://localhost:6817 --address <node private ip> > /var/log/spurd.log 2>&1 < /dev/null &'
```

`setsid nohup` inside `sudo sh -c` is needed: a plain `nohup ... &` over SSH
dies with the session. Give `spurd --address` the private IP, or the agent
registers as `127.0.1.1`.

`spur nodes` must list the hostname. When the log says `not the Raft leader`,
the agent started before the controller won its election: restart `spurd`.

## 7. Bring up Kubernetes

```bash
sudo spur k8s install-k0s
sudo spur k8s up --controller http://localhost:6817
sudo spur k8s status
```

Run `spur k8s up` as **root**: with accounting off, no other caller is a
cluster admin. Provisioning takes about a minute.

Gate: `sudo k0s kubectl get nodes` shows the node `Ready`, and
`sudo k0s kubectl get sc` shows `local-path` as the default StorageClass.

## 8. Install a profile

```bash
spur silo list
spur silo install scalable-inference --smoke-test
spur silo status
```

`install scalable-inference` asks Spur for the node GRES. A node with an AMD
Instinct GPU gets `scalable-inference-gpu`, which adds the AMD GPU operator.
`--no-gpu` keeps the CPU profile. The GPU operator uses the ROCm driver of the
host, so the host needs that driver; `amd-smi list` shows it.

Gate: every capability of the profile reads `yes` in `spur silo status`, the
node shows `amd.com/gpu: <count>` in its allocatable resources, and the smoke
test says `smoke test passed`.

## 9. Take it down again

```bash
spur silo uninstall <profile>          # or --keep-data to keep the PVCs and CRDs
sudo spur k8s down
sudo pkill spurd; sudo pkill spurctld
sudo k0s reset                         # only when k0s must go as well
sudo umount /var/lib/k0s
```

`uninstall` leaves the namespace `aims-test` of the smoke test and the
namespace `silo-system` of the install record. Both are empty.
