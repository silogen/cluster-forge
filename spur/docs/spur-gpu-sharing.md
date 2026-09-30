# Share the GPUs of a node between Spur and Kubernetes

Spur can share the GPUs of a node with the Kubernetes pods on that node. Such
a node is a shared node. A shared node runs the AMD DRA driver (driver name
`gpu.amd.com`) and not the AMD device plugin. The DRA driver tells the
scheduler which GPU a pod gets before the pod starts. Spur reads this
allocation and does not put a Spur job on that GPU. Spur also makes a
`ResourceClaim` for each Spur job, so the scheduler does not give the GPU of
a job to a pod.

Spur marks a shared node with the label `spur.amd.com/gpu-sharing=true`.

## Requirements

- Kubernetes 1.36 or later. The feature gate `DRAExtendedResource` is beta
  and on by default in 1.36. On 1.34 and 1.35 it is alpha: turn it on in the
  API server, the scheduler, the controller manager and the kubelet. Spur
  k0s v1.36.2 has the gate on with no change.
- The AMD GPU operator 1.5.1 (the `amd-gpu-operator` package).
- The AMD DRA driver v1.0.1. The `amd-gpu-operator-config` package sets this
  image.

## What the packages do

The `amd-gpu-operator-config` package has the value `gpuSharing.enabled`. It
is `false` by default. Then the package makes one `DeviceConfig`, and every
AMD GPU node gets the device plugin.

When `gpuSharing.enabled` is `true`, the package makes two `DeviceConfig`
objects and one `DeviceClass`:

| Object | Node selector | Component |
|---|---|---|
| `DeviceConfig` `gpu-operator` | `feature.node.kubernetes.io/amd-gpu=true`, `spur.amd.com/gpu-sharing=false` | Device plugin |
| `DeviceConfig` `gpu-operator-dra` | `feature.node.kubernetes.io/amd-gpu=true`, `spur.amd.com/gpu-sharing=true` | DRA driver `docker.io/rocm/k8s-gpu-dra-driver:v1.0.1` |
| `DeviceClass` `gpu.amd.com` | not applicable | `extendedResourceName: amd.com/gpu`, selector `device.driver == 'gpu.amd.com'` |

The two `DeviceConfig` selectors must not select the same node. The operator
does not accept a node that two `DeviceConfig` objects select, and it does not
accept one `DeviceConfig` with the device plugin and the DRA driver together.

The `amd-gpu-operator-config` package is the only owner of the `DeviceClass`.
The `amd-gpu-operator` package sets `draDriver.deviceClass.create: false`, so
the operator chart does not make a second class without the mapping. On
Kubernetes (not OpenShift) the operator controller does not write the class.
Thus a new install or a sync of the package keeps `extendedResourceName`.

The `DeviceConfig` selector compares labels for equality only. It cannot
select "a node without the label". Thus, when `gpuSharing.enabled` is `true`:

- Each ordinary GPU node must have the label `spur.amd.com/gpu-sharing=false`.
- A GPU node without the label gets no device plugin and no DRA driver.
- A GPU node must have the label `feature.node.kubernetes.io/amd-gpu=true`.
  Node Feature Discovery sets it on a bare-metal node. On a virtual machine
  with a virtual function GPU, set it yourself if it is missing.

Set the labels on an ordinary node:

```bash
kubectl label node <node> spur.amd.com/gpu-sharing=false
```

The operator keeps the first `DeviceConfig` of a node in memory until it
restarts. When you change the label of a node from `false` to `true` or
from `true` to `false`, restart the operator:

```bash
kubectl rollout restart deployment -n kube-amd-gpu \
  amd-gpu-operator-gpu-operator-charts-controller-manager
```

## Turn on GPU sharing

1. Let Spur mark the shared nodes, for example with
   `spur k8s up --gpu-sharing-nodes <node>` or
   `spur node gpu-sharing <node> on`. Spur sets
   `spur.amd.com/gpu-sharing=true`.
2. Label each ordinary GPU node `spur.amd.com/gpu-sharing=false`.
3. Install the profile `gpu-sharing`:

   ```bash
   spur aims install gpu-sharing
   ```

   The profile extends `default`. It sets `gpuSharing.enabled: true` and
   `podResourceAPISocketPath: /var/lib/k0s/kubelet/pod-resources`.
4. Make sure that the capability `gpu.spur-sharing` is present:

   ```bash
   spur aims status
   ```

   The probe of `gpu.spur-sharing` passes when a node with the label
   `spur.amd.com/gpu-sharing=true` has a `ResourceSlice` from the driver
   `gpu.amd.com`.
5. Make sure that the class has the mapping:

   ```bash
   kubectl get deviceclass gpu.amd.com -o jsonpath='{.spec.extendedResourceName}'
   ```

   The output must be `amd.com/gpu`.

## Pods on a shared node

A pod can request `amd.com/gpu` as on an ordinary node:

```yaml
resources:
  limits:
    amd.com/gpu: 1
```

The scheduler sees that the `DeviceClass` `gpu.amd.com` maps `amd.com/gpu`.
It makes a `ResourceClaim` with the name `<pod>-extended-resources-<suffix>`
in the namespace of the pod, and gives the pod a device from that claim. The
name is shorter when the pod name is long. The pod status field
`extendedResourceClaimStatus.resourceClaimName` gives the name. Spur reads
this claim as it reads every other claim. `scontrol show node` shows the GPU
as `held <namespace>/<pod> (claim <claim>)`.

AIM and KServe pods request `amd.com/gpu`, so they run on a shared node with
no change to AIM or KServe.

A pod can also request a GPU with a `ResourceClaim` or a
`ResourceClaimTemplate` on the `DeviceClass` `gpu.amd.com`:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: one-gpu
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: gpu.amd.com
---
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: one-gpu
  containers:
    - name: test
      image: docker.io/rocm/rocm-terminal:latest
      command: ["rocm-smi"]
      resources:
        claims:
          - name: gpu
```

## Move a node from the device plugin to DRA

When a node that had the device plugin becomes a shared node, the kubelet
keeps the field `amd.com/gpu` in the node status. It shows capacity `8` and
allocatable `0`, and after approximately 5 minutes `0` and `0`. The
scheduler ignores this field, because the `DeviceClass` maps `amd.com/gpu` to
DRA. But aim-engine v0.2.6 compares the AIM profile with the node allocatable.
When `amd.com/gpu` is in the allocatable and is less than the request,
aim-engine finds no supported profile, the `AIMModel` becomes `NotAvailable`,
and aim-engine does not make the InferenceService.

Remove the stale field after the 5 minutes:

```bash
kubectl patch node <node> --subresource=status --type=json -p '[
  {"op": "remove", "path": "/status/capacity/amd.com~1gpu"},
  {"op": "remove", "path": "/status/allocatable/amd.com~1gpu"}]'
```

The kubelet does not write the field again while no device plugin
registers `amd.com/gpu`. A node that was never a device plugin node does not
have the field.

## The kubelet path on k0s

k0s keeps the kubelet root in `/var/lib/k0s/kubelet`, not in
`/var/lib/kubelet`.

- Keep `podResourceAPISocketPath: /var/lib/k0s/kubelet/pod-resources` on
  k0s. The metrics exporters of both `DeviceConfig` objects use this value,
  on ordinary nodes and on shared nodes.
- On a shared node, Spur makes two symbolic links:
  `/var/lib/kubelet/plugins_registry` to
  `/var/lib/k0s/kubelet/plugins_registry`, and `/var/lib/kubelet/plugins` to
  `/var/lib/k0s/kubelet/plugins`. The DRA driver uses these default paths,
  and the links send it to the k0s kubelet. Spur does not link all of
  `/var/lib/kubelet`, because the k0s kubelet makes a real directory
  `/var/lib/kubelet/device-plugins`. Spur does not link `pod-resources`.

The metrics exporter of `gpu-operator-dra` uses the node port `32501`,
because the metrics exporter of `gpu-operator` already has `32500`. Two
Services cannot use the same node port.

## Known problems

- The DRA driver v1.0.1 does not start on a node where the `virtio_gpu`
  kernel module has a DRM card, for example a cloud virtual machine. Unload
  the module (`modprobe -r virtio_gpu`) before the driver starts.
- The check `spur/tests/check-gpu-sharing-render.sh` (`just
  gpu-sharing-render`) checks the rendered objects. It does not replace a
  test on GPU hardware.

## Test status

Tested on one node with 8 AMD Instinct MI325X virtual function GPUs in SPX
mode, k0s v1.36.2, operator 1.5.1 and DRA driver v1.0.1:

- A pod with `amd.com/gpu: 1` gets one GPU through a generated claim, and
  Spur shows the hold.
- An unchanged AIM (`aim-meta-llama-llama-3-1-8b-instruct:0.11.1`) serves a
  chat completion.
- An AIM and a Spur job run together on different GPUs, in both start orders.
- When all GPUs are in use, a new pod and a new Spur job wait. When a GPU
  becomes free, the next one starts.

Not tested: CPX partitions, more than one node, the ArgoCD path, and a
change from the `default` profile to `gpu-sharing` on a cluster where the
operator chart made the class.
