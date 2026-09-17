# Set up one node for byok with Spur

Every step of a single-node install, from a node that runs nothing to a
profile that serves a model. This is the path the GPU test of
`useocpm2m-silogen-014` took, step by step. A multi-node cluster adds only the
peer list of step 3 and a `spurd` on every node.

The node needs no helm, kubectl, yq, jq or git: the `spur-inference` binary
holds the charts. It does need to reach the container registries.

## 1. Build the binaries

Spur, from a checkout of the spur repository:

```bash
cargo build --release --bin spurctld --bin spurd --bin spur
```

`spur-inference`, from a checkout of cluster-forge. `make assets` needs helm and the
network once, `make build` needs neither:

```bash
make -C byok/spur-inference assets build REF=<branch-or-tag>
```

## 2. Copy them to the node

```bash
scp -C target/release/{spurctld,spurd,spur} ubuntu@<node>:/tmp/
scp -C byok/spur-inference/spur-inference ubuntu@<node>:/tmp/
ssh ubuntu@<node> 'sudo install -m755 /tmp/{spurctld,spurd,spur,spur-inference} /usr/local/bin/'
```

Check the size of every file on the node against the source. A copy that stops
in the middle gives a binary that starts and prints nothing, with no error.

`spur inference ...` works when the `spur` build holds the plugin mechanism.
`spur-inference ...` works with any build.

## 3. Write /etc/spur/spur.conf

```toml
cluster_name = "gpu1"

[controller]
listen_addr = "[::]:6817"
rest_addr = "[::]:6820"
raft_listen_addr = "[::]:6821"

[auth]
plugin = "none"

[metrics]
enabled = false

[[partitions]]
name = "gpu"
default = true
state = "UP"
nodes = "<hostname>"
max_time = "1-00:00:00"
default_time = "0:10:00"
min_nodes = 1

[cluster]
enabled = true
distro = "k0s"
control_plane_node = "<hostname>"
control_plane_replicas = 1
cni = "kuberouter"
storage_provisioner = "local-path"
local_path_dir = "/mnt/disk0/local-path-provisioner"
allow_admin_kubeconfig = true
```

One node needs no `node_id` and no `peers`: a single controller wins its own
election. A second controller needs both, and the ids must follow the order of
`peers`.

Four settings whose absence costs the most time:

- `cluster_name` is mandatory and sits at the top level. Without it `spurctld`
  exits with `missing field cluster_name`.
- `[cluster] enabled = true` must be there **before** `spurctld` starts. The
  reconcile loop only runs when it is set, and `spur k8s up` then stays in
  `provisioning` for ever.
- `allow_admin_kubeconfig = true` lets `spur-inference` ask Spur for the admin
  kubeconfig. Without it the plugin falls back to `sudo -n k0s kubeconfig
  admin`, which works on a control-plane node only.
- `local_path_dir` puts the volumes of the default StorageClass on the big
  disk. The default is `/var/lib/local-path-provisioner` on the root
  filesystem, and one model cache fills a normal root disk.
- Without a `[[partitions]]` block a node registers but belongs to no
  partition, so every batch job stays pending.

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

One AIM image with its cache is larger than a normal root disk. Two directories
grow: the k0s data directory and the volumes of the default StorageClass. The
second one is `local_path_dir` of step 3; the first is a bind mount, made
**before** `spur k8s up`:

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
spur inference list
spur inference install --smoke-test          # the default profile
spur inference status
```

Every command but `list` takes `--kubeconfig <path>`, which wins over the
lookup chain.

`install` with no name installs `default`, which holds the AMD GPU operator.
`--no-gpu` installs `default-cpu` instead. The plugin asks Spur for the GPU of
every node and prints a warning when the profile and the GPUs do not go
together, but it never changes the name. The GPU operator uses the ROCm
driver of the host, so the host needs that driver; `amd-smi list` shows it.

Gate: every capability of the profile reads `yes` in `spur inference status`, the
node shows `amd.com/gpu: <count>` in its allocatable resources, and the smoke
test says `smoke test passed`.

## 9. Take it down again

```bash
spur inference uninstall --yes         # every profile; --keep-data keeps the PVCs and CRDs
sudo spur k8s down --reset             # --reset wipes the k0s state as well
# `down` only files the request: spurctld drives spurd, which does the work.
# Wait for the unit to go before the daemons go, or the request is lost.
until ! systemctl is-active --quiet k0scontroller.service; do sleep 5; done
sudo pkill spurd; sudo pkill spurctld
sudo umount /var/lib/k0s
```

`spur k8s down` prints `k0s cluster down requested` and returns at once. A
`pkill` of the daemons before the unit is gone leaves k0s running, and a later
`spurd` does not take the request up again: it logs `adopted already-running
k0s unit on startup` and leaves the cluster as it is. `k0s reset` by hand is
not needed, `--reset` of `down` does it.

`uninstall` leaves the namespace `inference-system` of the install record, and the
namespace `aims-test` when the smoke test ran. Both are empty.
