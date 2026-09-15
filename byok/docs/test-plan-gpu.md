# Test plan: byok on a GPU node

This plan tests the byok install path on real AMD GPUs. The first byok release
was tested on CPU only. GPU is an open item in [Future work](future-work.md):
an AMD GPU operator package, the accelerator detector on, the Instinct catalog
family, and a footprint from a GPU node. This test gives all four.

## The node

`useocpm2m-silogen-014`, also known as `int-test-gpu-1` or `itg1`, at
10.0.0.163.

| Item | Value |
|---|---|
| GPU | 8 x AMD Instinct MI300X, gfx942 |
| CPU and memory | 112 cores, 2 TB |
| OS | Ubuntu 22.04.5, kernel 5.15.0-1074-oracle |
| ROCm | `/opt/rocm` on the host, `amd-smi` answers |
| Disks | root 248 G, `nvme0n1` as `/var/lib/rancher`, `nvme1n1` to `nvme7n1` as `/mnt/disk0` to `/mnt/disk6`, 3.5 T each |
| Today | An RKE2 agent of the int-test cluster. The node is cordoned and drained. |

The node goes back to the int-test cluster after the test. Therefore the test
must not change the disks that cluster-bloom uses.

## What is saved before the test

`/home/prepo/backups/useocpm2m-silogen-014/`, mode 700:

- `bloom.yaml`, the cluster-bloom configuration of the node. It holds
  `SERVER_IP`, `JOIN_TOKEN`, `RANCHER_DISK`, `CLUSTER_DISKS` and the Docker Hub
  credentials. The same file rebuilds the node.
- `config.yaml` and `registries.yaml` of RKE2.

The Docker Hub user is `silogenai`. The credentials give a pull of
`amdenterpriseai/aim-*`, which the test confirmed with the registry API. The
byok install uses the same credentials for the AIM model images.

## Announcement

The team channel `#enterprise-ai-platform-internal` holds the announcement
that the node leaves the int-test cluster.

## Phase 1: take the node out of the int-test cluster

1. On an int-test control-plane node: `kubectl delete node
   useocpm2m-silogen-014`.
2. On the GPU node: `sudo rke2-killall.sh`, then `sudo rke2-uninstall.sh`.
3. Remove the cluster-bloom leftovers: the Longhorn mounts under
   `/var/lib/longhorn`, the iptables rules of RKE2, and the `/var/lib/rancher`
   mount of `nvme0n1`.
4. Reboot.

Gate: `amd-smi list` shows 8 free GPUs, and `lsblk` shows no mount of the RKE2
disks.

## Phase 2: a single-node Spur k0s cluster

Build the binaries in `/home/prepo/dev/silo/spur`:

```bash
cargo build --release --bin spurctld --bin spurd --bin spur
```

Copy `spurctld`, `spurd` and `spur` to `/usr/local/bin` of the node.

`/etc/spur/spur.conf` for one node:

- `cluster_name` at the top level. The daemon does not start without it.
- `[controller] node_id = 1` and `peers` with the own address only.
- `[cluster] enabled = true` before `spurctld` starts, and
  `allow_admin_kubeconfig = true`, because `byok/spur/spur-silo` asks Spur for
  the admin kubeconfig.
- One `[[partitions]]` block with the hostname of the node.

Open the k0s CIDRs in the host firewall, `10.244.0.0/16` and `10.96.0.0/12`.
The kube-router workaround of the three-node test is not needed, because there
is one node.

Move the k0s data directory to an NVMe disk before `spur k8s up`, for example
a bind mount of `/mnt/disk0` on `/var/lib/k0s`. The root disk has 225 G free,
and one AIM image with its cache is larger than that.

```bash
sudo spur k8s install-k0s
sudo spur k8s up --controller http://localhost:6817
sudo spur k8s status
```

Gate: `kubectl get nodes` shows one Ready node that is also a worker, and
`local-path` is the default StorageClass.

## Phase 3: the GPU operator

The host has the ROCm driver, so the `DeviceConfig` keeps `driver.enable:
false` and uses that driver. This is the default of
`sources/amd-gpu-operator-config/v1.4.1`.

Install `sources/amd-gpu-operator/v1.4.1` and
`sources/amd-gpu-operator-config/v1.4.1` with `helm upgrade --install` into
`kube-amd-gpu`, with `crds.defaultCR.install=false`, the same values that
`root/values.yaml` gives the ArgoCD path. The operator needs cert-manager, so
this step runs after the byok install of Phase 4, or after a byok install of
cert-manager alone.

Gate: the node shows `amd.com/gpu: 8` in its capacity, and one test Pod runs
`rocm-smi` and sees the GPUs.

Make two byok packages, `amd-gpu-operator` and `amd-gpu-operator-config`, when
the manual install works. The capability name `gpu.amd` is already reserved in
`capabilities.yaml`. The probe reads the GPU capacity of a node.

## Phase 4: aim-engine only, on GPU

A new profile `byok/profiles/scalable-inference-gpu.yaml` that extends
`scalable-inference`:

- `aim-catalog` with `hardwareFamilies: [instinct]` in place of `epyc`.
- `aim-engine` with `acceleratorDetector.enable: true`. The GPU operator brings
  Node Feature Discovery, which the detector needs.
- `kyverno` and `kyverno-policies-storage-local-path` stay, because local-path
  gives ReadWriteOnce only.

Install from a checkout on the node, because the profile is not pushed:

```bash
tar czf /tmp/cf.tgz byok sources root && scp /tmp/cf.tgz ubuntu@10.0.0.163:
ssh ubuntu@10.0.0.163 'mkdir -p cf && tar xzf cf.tgz -C cf'
ssh ubuntu@10.0.0.163 'cf/byok/spur/spur-silo install scalable-inference-gpu'
```

`install scalable-inference` selects the GPU profile by itself when a node
reports an AMD Instinct GPU to Spur; the name above asks for it directly.

The AIM images are public on Docker Hub. Give `--pull-secret <docker-config>`
only to lift the rate limit of an anonymous pull.

`tests/smoke.sh` runs the CPU dummy, so the GPU test needs a second object,
`tests/aimservice-gpu.yaml`, with
`amdenterpriseai/aim-meta-llama-llama-3-1-8b-instruct:0.8.5` and one GPU. The
steps stay the same: wait for `Ready`, port-forward the predictor Service, and
send a `/v1/chat/completions` request.

Measure the footprint with `footprint/footprint.sh` and write
`docs/footprint-scalable-inference-gpu.md`.

Gate: the model answers from the GPU. Write every finding in
[Future work](future-work.md).

A larger model on 8 GPUs comes only after the 8B model answers.

## Phase 5: the aiwb-demo profile

Two possible ways. The first way is also a test result.

1. Install `aiwb-demo` on top of the same cluster. The risk is known: the
   `aiwb` chart and the `aim-engine` chart make the same
   `AIMClusterRuntimeConfig default` object, and the `scalable-inference`
   profile gives that object to `aim-engine`. If Helm refuses, that is a
   finding for [Future work](future-work.md).
2. If way 1 fails: `spur k8s down`, `spur k8s up`, then `aiwb-demo` alone.

The node has no load balancer and no public DNS name, so:

```bash
cf/byok/spur/spur-silo install aiwb-demo \
  --var domain=10.0.0.163.nip.io \
  --var gatewayServiceType=ClusterIP \
  --var gatewayExternalIP=10.0.0.163
```

That gives the node address to the Envoy Service in `externalIPs`.

Confirm that a browser on the workstation reaches port 443 of 10.0.0.163. If it
does not, run `tests/smoke-ui.sh` on the node, because the test uses curl only,
and look at the UI through an SSH tunnel.

Tests: `tests/smoke-ui.sh` and `NAMESPACE=workbench tests/smoke.sh`. Last,
deploy a GPU model from the catalog with the AIWB UI and chat with it. That is
the demo which the profile exists for.

## Phase 6: give the node back

Ask before this phase starts.

1. Stop and remove Spur and k0s: `sudo spur k8s down`, then
   `sudo spur k8s install-k0s --uninstall` or the k0s reset, and remove
   `/etc/spur`, the binaries and the bind mount.
2. Install cluster-bloom with the saved `bloom.yaml`. The file holds the join
   token and the disks of the int-test cluster.
3. Confirm that the node is Ready in the int-test cluster and that the GPUs
   show in its capacity.

## Out of scope

- More than one node, and high availability.
- S3. The `seaweedfs` packages stay comments in the `aiwb-demo` profile.
- AIRM, Kaiwo and Kueue. They are not part of the byok path.
