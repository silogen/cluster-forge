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
- Make `ghcr.io/silogen/aim-dummy` public, or copy it to `amdenterpriseai`, so
  that the smoke test needs no pull secret.
- One source of truth for the versions of the ArgoCD path and the byok path.
  Today `tests/check-version-drift.sh` compares them.
- Add `byok/` to the release tarball.
- An air-gapped install with vendored charts.
- A profile override file for `bootstrap.sh`, `--values <file>`.
- An upgrade test with two published chart versions.
- byok on more than one node, and high availability.
- Repair or remove `docs/manual_helm_install`.
