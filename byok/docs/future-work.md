# byok future work

These items are out of scope for the first byok release.

- The kserve package fails on a cold single node: `helm_install_retry` gives
  three attempts 20 seconds apart, and the webhook of the release needs longer
  when the image still pulls. A second run of the installer passes. Make the
  retry wait for the webhook Deployment instead of a fixed sleep.
- The AIM images of the 0.8.5 release do not run on a host whose amdgpu
  driver is older than their ROCm. On `useocpm2m-silogen-014`, driver
  6.19.14 with the ROCm 7.0.2 amdsmi of the image, `amdsmi_get_gpu_activity`
  answers AMDSMI_STATUS_UNEXPECTED_DATA. The GPU detector of the runtime
  holds all three amdsmi calls in one try block, so one failing call hides
  the GPU: it reports `Detected GPU: NONE`, finds no compatible profile and
  the predictor container exits. The `amd-smi` command line of the same
  image reads the GPU without fault, and the aim-base 0.12 image answers the
  same call without fault. Ask the aim-engine team to read the activity of a
  GPU in its own try block. The GPU test uses the 0.11.1 image.
- The CPU accelerator detector of the aim-engine chart has no node affinity,
  although its values comment says it targets nodes without a GPU. On an
  MI300X node it reports `model=CPU count=1` and its startup probe never
  passes, so the DaemonSet stays 0/1. The `default` profile turns it off.
  Ask the aim-engine team for the node affinity.
- The accelerator detector images live in `amdenterpriseai` and the chart
  ships an empty `imagePullSecrets`. The images are public today, so a pull
  Secret only lifts the rate limit of an anonymous pull. A byok package that
  makes registry Secrets from one place would remove the manual step when a
  registry does need credentials.
- `footprint/footprint.sh` stops with a jq error when a container writes a
  memory value without the binary suffix, for example `4G` in place of `4Gi`.
  The GPU footprint is therefore not measured yet. Read the quantity with a
  suffix table instead of `tonumber`.
- The `absence of components` step of `tests/smoke.sh` holds every Pod of the
  cluster to Running or Succeeded, so a GPU cluster fails the step while any
  Pod of `kube-amd-gpu` is not ready, although steps 1 to 7 pass. Give the
  step a namespace list, or run it only for the minimal core.
- Blueprints on top of the default profile.
- An AIRM package. The `demo` profile holds AIWB without AIRM.
- Autoscaling as a capability that the cluster gives, `autoscaling.keda`, with
  a probe.
- The EPYC llama-3.2-1b model as a more realistic smoke test, after the CPU
  features of the test VM are confirmed.
- Copy `ghcr.io/silogen/aim-dummy` to `amdenterpriseai`, so that the smoke test
  does not depend on a silogen image. The image is public today.
- One source of truth for the versions of the ArgoCD path and the byok path.
  Today `tests/check-version-drift.sh` compares them.
- Add `byok/` to the release tarball.
- An air-gapped install with vendored charts.
- A profile override file for the plugin, `--values <file>`.
- An upgrade test with two published chart versions.
- byok on more than one node, and high availability. The three-node Spur test
  on OCI needed kube-router in full overlay mode, because an OCI VNIC drops a
  packet whose source address is a pod address. The workaround was this edit on
  the control-plane node, which k0s applies within a minute:

  ```bash
  sudo sed -i 's|- "--run-router=true"|- "--run-router=true"\n        - "--overlay-type=full"\n        - "--enable-overlay=true"|' \
    /var/lib/k0s/manifests/kuberouter/kube-router.yaml
  ```

  Spur could set this for OCI nodes itself.
- Remove `docs/manual_helm_install`: EAI-8674.
- A branded Dex login page for the demo. Today the demo shows the stock Dex
  page.
- Rename the `keycloak` values block of the aiwb chart to `oidc` in one
  breaking change. Today the `oidc` block derives its defaults from it.
  EAI-5551 is related.
- S3 for a demo as one `weed server -s3` Pod without the operator, when a
  profile needs S3 with the smallest footprint.
- Ask the AIWB team for a switch that stops the `OpenTelemetryCollector`
  object. Then the `opentelemetry-crds` package can go away.
- The `AIMClusterRuntimeConfig default` object: both the aim-engine chart and
  the aiwb chart make it under the same name, so only one release can own it.
  In `demo` the aiwb chart owns it, and it sets `pvcHeadroomPercent: 100`
  where the CRD default is 10, so a model volume is about two times the model
  size.
- Ask the AIWB team to make the `cluster-auth-admin-token` and
  `minio-credentials` references optional. Today the demo makes both Secrets
  with dummy values, because a `secretKeyRef` is not optional.
- Move the aiwb-chart pin from 2.0.0 to 2.0.1 in the ArgoCD path and in byok
  together.
- `extends` of more than one level, and removal of a base package, when a
  third profile needs them.
- Ask the aim-engine team for a value that stops the controller from watching
  Gateway and HTTPRoute. Then the `gateway-api-crds` package can go away.
- Ask the aim-engine team for a cache access mode that follows
  `caching.mode: Dedicated`. Today every cache claim is ReadWriteMany, so a
  cluster with ReadWriteOnce storage needs Kyverno.
- Merge the CRD packages back into their parent packages if helm learns to
  build a release manifest after the CRDs of the same release apply.
