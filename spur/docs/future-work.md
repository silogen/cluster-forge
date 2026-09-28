# Future work for AIMs in a Spur Kubernetes cluster

These items are out of scope for the first release of AIMs in a Spur Kubernetes cluster.

## Suggested next items

The list is in order of priority. The first items block a release or a test
on a real cluster. The last items are requests to other teams.

1. Merge the Spur plugin mechanism, ROCm/spur#925. `spur aims` works only
   with a `spur` build from the `feat/cli-plugins` branch. Until the merge,
   the user must run `spur-aims` directly.
2. Test the branch again on a CPU-only node and on itg1. The last CPU round
   ran on 2026-09-17, before the move to aim-engine 0.2.6 and aiwb-chart
   2.0.4-rc.1 and before the rename of `byok/` to `spur/`. A single-node GPU
   round passed on 2026-09-28, see
   [Manual steps of a single-node GPU test](manual-steps-single-node-gpu.md). Use a Spur build that includes
   ROCm/spur#861, and a three-node cluster without the kube-router edit.
3. Add `spur/` and a `spur-aims` binary to the release pipeline. Today the
   release tarball holds `root/`, `scripts/` and `sources/` only.
4. Make the kserve install retry wait for the webhook Deployment. See
   [Open items](#open-items). A cold single node fails the first install.
5. Give step 8 of `tests/smoke.sh` a namespace list, so that `just
   smoke-gpu` passes on a GPU cluster.
6. Merge the GPU detection fixes of `spur-devices`. ROCm/spur#927 ignores the
   CDI specs of DRA drivers, and ROCm/spur#942 decodes CPX partitions to the
   parent PCI device. `install` and
   `validate` read the GPUs of each node from Spur for the profile warning, so
   a wrong GPU count or model gives a wrong warning.
7. Merge the raft pull requests of `spurctld` before a test of a Spur
   controller with high availability: ROCm/spur#806, #810, #843, #844 and
   #785.
8. Copy `ghcr.io/silogen/aim-dummy` to `amdenterpriseai`.
9. Send the requests to the aim-engine team as one issue: the GPU activity
   call in its own try block, the node affinity of the CPU detector, a value
   that stops the Gateway and HTTPRoute watch, and a cache access mode that
   follows `caching.mode: Dedicated`.
10. Send the requests to the AIWB team as one issue: a switch that stops the
    `OpenTelemetryCollector` object, an optional reference to
    `minio-credentials`, and the rename of the `keycloak` values block to
    `oidc`.
11. A profile override file for the plugin, `--values <file>`.
12. Tell the core team that ai-gateway-discovery closes the model routes of
    a namespace only in the last step of its reconcile. When an earlier step
    fails, for example the `InferencePool` or the `AIGatewayRoute`, the
    `workloads-extauth` policy is not made and the routes stay open. See
    [ADR 0007](adr/0007-dex-token-on-the-model-routes-of-the-demo.md).
13. Document the Spur node settings for a node with a public address, and
    use ROCm/spur-toolkit for the node install. `spurctld` and `spurd` listen
    on every interface, and `docs/spur-node-setup.md` sets
    `[auth] plugin = "none"`, so any host that reaches ports 6817, 6818 and
    6821 can run work as root. The toolkit gives systemd units and native
    auth with `spur_auth_mode: required`, but no listen address and no
    firewall. Ask upstream for a listen address variable.

## Open items

- The kserve package fails on a cold single node. The install retry of
  `helmops.go` gives three attempts 20 seconds apart, and the webhook of the
  release needs longer when the image still pulls. A second run of the
  installer passes. Make the retry wait for the webhook Deployment instead of
  a fixed sleep.
- The AIM images of the 0.8.5 release do not run on a host whose amdgpu
  driver is older than their ROCm. On `useocpm2m-silogen-014`, driver
  6.19.14 with the ROCm 7.0.2 amdsmi of the image, `amdsmi_get_gpu_activity`
  answers AMDSMI_STATUS_UNEXPECTED_DATA. The GPU detector of the runtime
  holds all three amdsmi calls in one try block, so one failing call hides
  the GPU. It reports `Detected GPU: NONE`, finds no compatible profile and
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
  Secret only lifts the rate limit of an anonymous pull. A Spur package that
  makes registry Secrets from one place would remove the manual step when a
  registry does need credentials.
- The `absence of components` step of `tests/smoke.sh` holds every Pod of the
  cluster to Running or Succeeded, so a GPU cluster fails the step while any
  Pod of `kube-amd-gpu` is not ready, although steps 1 to 7 pass. Give the
  step a namespace list. The step now runs only in the namespace
  `aims-test`, but `just smoke-gpu` also uses that namespace.
- Node-feature-discovery for the `-cpu` profiles, so that the CPU detector
  of aim-engine can label the node. Today the `-cpu` profiles run no
  detector, because the result would go into a feature file that nothing reads.
- A `default` install on a cluster with no GPU fills the disk. The catalog
  of `default` discovers every Instinct model, and each discovery pod pulls a
  model image of about 10 GiB. On a CPU-only node with a 96 GiB disk the worker
  pulled about 80 GiB in 25 minutes, and the uninstall then timed out in the
  pre-delete hook of `amd-gpu-operator`. The `install` warning must name the
  image pulls, and the discovery pods must not pull an image on a node with
  no GPU.
- `aim-catalog` does not remove the pods of its discovery Jobs. Ten minutes
  after an install, `aim-system` held 160 `Succeeded` pods. Ask the
  aim-engine team for `ttlSecondsAfterFinished` on the Job.
- The cert-manager pods declare no requests and no limits, so the scheduler
  does not see them.
- The values of `envoy-gateway-config` set the node selector
  `cluster-bloom/first-node: "true"`. No k0s cluster has that label, and
  `install demo` warns `cannot overwrite table with non table for
  ...envoyProxy.nodeSelector`. The profile cannot override the value.
- Two empty namespaces stay after an uninstall: `aims-test` from
  `--smoke-test` and `aims-system` from the `demo` install. Neither is the
  namespace of a package, so the purge does not remove them.
- An uninstall keeps more CRDs than necessary. It keeps a CRD when a package
  that stays ships the same name in its chart, also when nothing that stays
  uses the API group. The CRDs go later with the base profile. Make the
  decision from the live owners, not from the chart names.
- The warning for a GPU that is not Instinct is not tested on a node with a
  Radeon card. Only the table test of `kube_test.go` checks it.
- Blueprints on top of the default profile.
- An AIRM package. The `demo` profile holds AIWB without AIRM.
- Autoscaling as a capability that the cluster gives, `autoscaling.keda`, with
  a probe.
- The EPYC llama-3.2-1b model as a more realistic smoke test, after the CPU
  features of the test VM are known.
- Copy `ghcr.io/silogen/aim-dummy` to `amdenterpriseai`, so that the smoke test
  does not depend on a silogen image. The image is public today.
- One source of truth for the versions of the ArgoCD path and the Spur path.
  Today `tests/check-version-drift.sh` compares them.
- Add `spur/` to the release tarball.
- An air-gapped install with vendored charts. This is partly done. The
  `spur-aims` binary holds every chart of its release.
  `docs/airgap/hauler.sh --profile` packs the charts and images of one Spur
  profile, and `dehauler.sh` applies them. No one has tested this end to end
  with `spur aims install`.
- A profile override file for the plugin, `--values <file>`.
- An upgrade test with two published chart versions.
- High availability of the Spur controller. The raft pull requests of
  `spurctld` are open: ROCm/spur#806, #810, #843, #844 and #785.
- Remove `docs/manual_helm_install`. EAI-8674 tracks this.
- Persistent storage for Dex, so that a restart of the Dex Pod does not make
  every token of `just show-token-demo` invalid. The `kubernetes` storage of Dex
  needs cluster-scoped RBAC for its CRDs.
- A branded Dex login page for the demo. Today the demo shows the stock Dex
  page.
- Rename the `keycloak` values block of the aiwb chart to `oidc` in one
  breaking change. Today the `oidc` block derives its defaults from it.
  EAI-5551 is related.
- S3 for a demo as one `weed server -s3` Pod without the operator, when a
  profile needs S3 with the smallest footprint.
- Ask the AIWB team for a switch that stops the `OpenTelemetryCollector`
  object. Then the `opentelemetry-crds` package can go away.
- The `AIMClusterRuntimeConfig default` object. Both the aim-engine chart and
  the aiwb chart make it under the same name, so only one release can own it.
  In `demo` the aiwb chart owns it, and it sets `pvcHeadroomPercent: 100`
  where the CRD default is 10, so a model volume is about two times the model
  size.
- Ask the AIWB team to make the `minio-credentials` reference optional.
  Today the demo makes the Secret with empty values, because a
  `secretKeyRef` is not optional.
- `extends` of more than one level, and removal of a base package, when a
  third profile needs them.
- Ask the aim-engine team for a value that stops the controller from watching
  Gateway and HTTPRoute. Then the `gateway-api-crds` package can go away.
- Ask the aim-engine team for a cache access mode that follows
  `caching.mode: Dedicated`. Today every cache claim is ReadWriteMany, so a
  cluster with ReadWriteOnce storage needs Kyverno.
- Merge the CRD packages back into their parent packages if helm learns to
  build a release manifest after the CRDs of the same release apply.

## Done

- The demo sets `openBao.enabled: false` of aiwb-chart 2.0.4-rc.1 and makes
  no `aiwb-openbao-token` Secret. The Go probe of `secrets.demo` looked for
  `cluster-auth-admin-token`, a Secret that nothing makes, so it never passed
  and a profile without the `aiwb-demo-secrets` package failed validation.
  A test now holds the probe to the Secrets that the package renders.
- The model routes of the demo ask for a Dex token, see
  [ADR 0007](adr/0007-dex-token-on-the-model-routes-of-the-demo.md).
  Before this change, the routes on `workloads.<domain>` answered without a
  token. `just show-token-demo` prints a token that is valid for 7 days, and
  a curl example. Tested on a GPU node on 2026-09-28: 401 without a token or
  with a wrong token, 200 with a token, and `just smoke-ui` passes.
- Pod traffic between the nodes of a Spur Kubernetes cluster on OCI. An OCI
  VNIC drops a packet whose source address is a pod address, so kube-router
  must run in full overlay mode. ROCm/spur#861, merged on 2026-09-18, makes
  `spurctld` run kube-router in full overlay mode and pins its CIDRs. The
  issue was ROCm/spur#852. With a Spur build older than that change, edit the
  kube-router manifest on the control-plane node. k0s applies the edit within
  a minute:

  ```bash
  sudo sed -i 's|- "--run-router=true"|- "--run-router=true"\n        - "--overlay-type=full"\n        - "--enable-overlay=true"|' \
    /var/lib/k0s/manifests/kuberouter/kube-router.yaml
  ```

- The tests of a Spur Kubernetes cluster found these faults in Spur. The fixes
  merged on 2026-09-18 or later:
  - ROCm/spur#854 makes `spur k8s` fail fast when the controller does not
    answer.
  - ROCm/spur#851 mounts `spur.conf` from a Secret.
  - ROCm/spur#809 recovers a node that the controller forgot.
  - ROCm/spur#808 keeps the cancel of a deleted SpurJob.
  - ROCm/spur#807 gives resolvable pod names to `SPUR_PEER_NODES`.
  - ROCm/spur#784 keeps the node record when its agent stops.
