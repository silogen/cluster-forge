# byok future work

These items are out of scope for the first byok release.

- A `gateway` package: Envoy Gateway and a Gateway object, with
  `routing.enabled: true`. Capability name `gateway.api`.
- GPU: an AMD GPU operator package, the accelerator detector on, the Instinct
  catalog family, and a footprint measured on a GPU node.
- Blueprints on top of the inference profile.
- AIRM and AIWB packages, with seaweedfs as their declared storage dependency.
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
- A profile override file for `bootstrap.sh`, `--values <file>`.
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
- Repair or remove `docs/manual_helm_install`.
- Ask the aim-engine team for a value that stops the controller from watching
  Gateway and HTTPRoute. Then the `gateway-api-crds` package can go away.
- Ask the aim-engine team for a cache access mode that follows
  `caching.mode: Dedicated`. Today every cache claim is ReadWriteMany, so a
  cluster with ReadWriteOnce storage needs Kyverno.
- Merge the CRD packages back into their parent packages if helm learns to
  build a release manifest after the CRDs of the same release apply.
