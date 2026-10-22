# GPU partitioning

Set AMD Instinct GPUs to compute partition `CPX` on an Enterprise AI reference stack node, and reapply that mode on every boot.

`CPX` exposes each XCC as its own logical GPU. A process that holds `/dev/kfd` blocks the change even when it is using no VRAM. The mode is a property of the physical GPU and is not kept across reboot: the driver comes back on the default accelerator profile, so a oneshot unit has to set `CPX` again before anything opens the device.

Run the node commands on the GPU node. Run the `kubectl` commands against the cluster. The Argo CD Application names below are the ones Cluster Forge installs; confirm them on the cluster before patching.

## Check the modes this GPU actually supports

Supported accelerator and memory modes depend on the ASIC and the firmware. Set only a mode that this node lists.

```bash
sudo amd-smi partition --current
sudo amd-smi partition --memory
sudo amd-smi partition --accelerator --gpu 0
```

`amd-smi` is the current CLI. `rocm-smi` is the older binary and is still what `--showpids` belongs to. If `amd-smi` is not on `PATH`:

```bash
command -v amd-smi || command -v /opt/rocm/bin/amd-smi
```

`CPX` makes one logical GPU per XCC. How many XCCs a card has depends on the ASIC, and `amd-smi partition --accelerator` is the count for this node. After the device plugin and node labeller pick up the new topology, allocatable `amd.com/gpu` is physical GPUs times that count, and labels such as `amd.com/gpu.vram` and `amd.com/gpu.cu-count` describe one partition rather than the whole card.

## Make the GPUs idle

Cordon the node, then stop workloads that use the GPU. `kubectl drain` does not remove DaemonSets, and those are the usual holders of `/dev/kfd`.

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=60
```

`--delete-emptydir-data` removes emptyDir contents on that node so the drain can finish.

### In-cluster metrics exporter

The GPU Operator metrics exporter (`gpuagent`) keeps `/dev/kfd` open. The root Argo CD Application `cluster-forge` re-renders child Applications and puts their sync policy back, so pause that Application first, then `amd-gpu-operator-config`.

```bash
kubectl -n argocd patch application cluster-forge --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application amd-gpu-operator-config --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n kube-amd-gpu patch deviceconfig gpu-operator --type merge \
  -p '{"spec":{"metricsExporter":{"enable":false}}}'
kubectl -n kube-amd-gpu get daemonset gpu-operator-metrics-exporter
```

Wait until that DaemonSet is gone before continuing.

### Host Docker exporter

Disabling `metricsExporter` removes only the DaemonSet. A node image can also run a host Docker metrics exporter that holds `/dev/kfd` (often named `device-metrics-exporter`, process `gpuagent`). That container uses Docker's containerd socket (`/run/containerd/containerd.sock`, namespace `moby`). It does not appear in RKE2 `crictl` or `ctr -n k8s.io`.

If that container is present, stop it for the duration of the change:

```bash
sudo docker ps --filter name=device-metrics-exporter
sudo docker update --restart=no device-metrics-exporter
sudo docker stop device-metrics-exporter
```

### Confirm nothing is using the cards

Run both checks. An empty process list from the SMI tool is not enough on its own: a holder can show 0 VRAM and still block `amd-smi set`.

`rocm-smi --showpids` lists KFD process IDs. No PIDs means this check is clear.

```bash
sudo rocm-smi --showpids
```

`--showpids` is a `rocm-smi` flag. Where that binary is not installed, use `amd-smi process`.

```bash
sudo amd-smi process
```

Then confirm nothing has the device open. `fuser` prints no process lines when `/dev/kfd` is free.

```bash
sudo fuser -v /dev/kfd
```

If either command still shows a process, stop its owner. Killing the PID only gets it restarted.

```bash
sudo ls -l /proc/<pid>/exe
pstree -asp <pid>
ps -o pid,ppid,unit,cmd -p <pid>
```

| Parent or cgroup | Owner | Stop it with |
|---|---|---|
| `containerd-shim` `-namespace moby`, or `docker-<id>.scope` | host Docker container | `sudo docker update --restart=no <name>` then `sudo docker stop <name>` |
| `-namespace k8s.io`, cgroup under `kubepods` | Kubernetes pod | the owning DaemonSet or Deployment, not the PID |
| PPID 1 and a `*.service` unit | host systemd service | `sudo systemctl stop <unit>` |

Repeat `--showpids` and `fuser` until both are clear, on every node you are changing.

## Set the compute partition

Compute partition does not need a driver reload.

```bash
sudo amd-smi set --gpu all --compute-partition CPX
sudo amd-smi partition --current
amd-smi list
```

`amd-smi list` should show one logical GPU per XCC. The number per physical GPU is whatever `amd-smi partition --accelerator` reported for `CPX` on this ASIC.

### Memory partition

Leave the memory partition at `NPS1`. `CPX` is the compute change; `NPS1` is the memory mode this procedure keeps, and it is the usual default, so a node already on `NPS1` needs no memory command. Do not set `NPS2` as part of enabling `CPX`.

`CPX` with `NPS2` is not supported by every GPU, driver, and firmware
combination. AMD added that combination for Instinct MI350X and MI355X in
AMD GPU Driver (`amdgpu`) 30.20.0, with PLDM firmware bundle 01.25.15.04 or
later. Earlier drivers do not support it on those GPUs. For other ASICs, or
newer combinations, treat the modes reported by
`amd-smi partition --accelerator` and `amd-smi partition --memory` as the
authority and check the
[AMD partitioning compatibility matrix](https://instinct.docs.amd.com/projects/amdgpu-docs/en/latest/gpu-partitioning/index.html).
Driver support means the combination is available; it does not replace
workload validation. Keep `NPS1` unless the deployment specifically requires
and has validated another mode.

A memory-mode change is a separate manual step, and it does not belong in the oneshot unit:

- `amd-smi set --memory-partition` asks for confirmation, so a unit with no TTY hangs on it.
- The set does not take effect until the driver is reloaded, and the reload can put the accelerator profile back to the hardware default. Set `CPX` after the reload, not before.

```bash
sudo amd-smi set --gpu all --memory-partition <NPS1|NPS2|NPS4>
sudo modprobe -r amdgpu && sudo modprobe amdgpu
```

Wait until `/dev/kfd` exists again, then run the `CPX` command above. `modprobe -r amdgpu` unloads the driver for every GPU on the node, so this stays inside the same idle window.

## Reapply CPX on boot

Install this unit on each GPU node. It sets `CPX` after `amdgpu` has created `/dev/kfd`, and before RKE2, kubelet, Slurm, or Docker can open the device.

On an Enterprise AI reference stack node, kubelet runs inside `rke2-agent.service` or `rke2-server.service`. The host Docker exporter starts with `docker.service`. The unit is ordered before those services so they open `/dev/kfd` only after `CPX` is set. A `Before=` entry for a unit that is not installed is ignored.

`After=systemd-modules-load.service` does not mean `/dev/kfd` exists yet. The `ExecStartPre` loop waits for the device. `TimeoutStartSec=600` keeps systemd from killing the set while the GPUs on the node are still resetting. `ExecStartPost` retries `partition --current` for the same reason. `Before=` only orders the boot; if this unit fails, RKE2 still starts, on the default profile. Check the unit after every reboot.

Enable the unit only on GPU nodes. The `ExecStartPre` wait is 60 seconds, and anything ordered after this unit waits with it.

Replace `/opt/rocm/bin/amd-smi` if `command -v amd-smi` prints a different path. The unit needs an absolute path.

```bash
command -v amd-smi
```

```ini
# /etc/systemd/system/amd-cpx.service
[Unit]
Description=Configure AMD GPUs in CPX mode
After=systemd-modules-load.service
Before=kubelet.service rke2-agent.service rke2-server.service slurmd.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=600
ExecStartPre=/bin/bash -c 'for _ in $(seq 1 60); do [ -e /dev/kfd ] && exit 0; sleep 1; done; echo "timed out waiting for /dev/kfd" >&2; exit 1'
ExecStart=/opt/rocm/bin/amd-smi set --gpu all --compute-partition CPX
ExecStartPost=/bin/bash -c 'for _ in $(seq 1 30); do /opt/rocm/bin/amd-smi partition --current && exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=multi-user.target
```

Install it while the node is still idle. `--now` runs the set immediately and enables it for the next boot. Restart the unit only while every partition of the physical GPU is idle.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now amd-cpx.service
systemctl status amd-cpx.service
```

`partition --current` from the unit is in the journal:

```bash
sudo journalctl -u amd-cpx.service -b
```

## Recreate the device plugin and node labeller

The device plugin reports the GPU count it saw at startup. Until its pod is replaced, the node keeps advertising the old `amd.com/gpu` count. The GPU Operator owns these DaemonSets and rewrites their pod template from the `DeviceConfig`, which drops `kubectl.kubernetes.io/restartedAt`. `kubectl rollout restart` does not stick. Delete the pods by name prefix. The label `daemonset-name=gpu-operator` is shared with the metrics exporter and the node labeller, so do not delete by that label.

```bash
kubectl -n kube-amd-gpu get pods -o name \
  | grep '^pod/gpu-operator-device-plugin-' \
  | xargs -r kubectl -n kube-amd-gpu delete
kubectl -n kube-amd-gpu get pods -o name \
  | grep '^pod/gpu-operator-node-labeller-' \
  | xargs -r kubectl -n kube-amd-gpu delete
```

Wait until those pods are new (seconds or minutes, not days). A reboot with `amd-cpx.service` enabled also comes up with the new topology, because the set finishes before RKE2 starts the plugin. A node that was partitioned live still needs the deletes above.

`kubectl get nodes -o custom-columns` prints `<none>` for `amd.com/gpu` because of the slash in the resource name. Read the allocatable count with `jq`:

```bash
kubectl get nodes -o json | jq -r \
  '.items[] | [.metadata.name, (.status.allocatable["amd.com/gpu"] // "-")] | @tsv'
```

The expected value is the number of physical GPUs multiplied by the `CPX` partition count from `amd-smi partition --accelerator`. A node still showing the pre-change count has a plugin pod older than the partition change.

## Put the node back in service

Restore automated sync on the operator Application first, then the root Application. Self-heal turns the metrics exporter back on. A lasting change to that exporter belongs in the cluster values repository; a live patch is reverted when self-heal returns.

```bash
kubectl -n argocd patch application amd-gpu-operator-config --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
kubectl -n argocd patch application cluster-forge --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
```

If a host container was stopped, restore its restart policy and start it after `CPX` is set:

```bash
sudo docker update --restart=unless-stopped device-metrics-exporter
sudo docker start device-metrics-exporter
```

Uncordon once the allocatable count and the node labels match the new mode:

```bash
kubectl uncordon <node>
```

## Return to a single logical GPU

Stop holders of `/dev/kfd` the same way, disable the oneshot so the next boot does not set `CPX` again, then set `SPX`.

```bash
sudo systemctl disable --now amd-cpx.service
sudo amd-smi set --gpu all --compute-partition SPX
sudo amd-smi partition --current
```

Recreate the device-plugin and node-labeller pods, then uncordon. In `SPX`, allocatable `amd.com/gpu` equals the number of physical GPUs.
