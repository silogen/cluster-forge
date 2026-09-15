# spur-silo test findings

What the tests of the `spur silo` plugin found. Each item says where it was
found and what the state is. The Go rewrite of the plugin keeps this list as
its input.

## Test setup

Two Kaytoo VMs, 2026-09-15. Spur 0.12.0 from the `feat/cli-plugins` worktree,
`spurctld` and `spurd` on both nodes, `spur k8s up` with k0s v1.36.2+k0s.0.
Control plane `useocpm2m-silogen-petrus-u7pjc4`, worker (the driver node)
`useocpm2m-silogen-petrus-zqx78g`. cluster-forge ref `EAI-8560-byok`.

## Fixed during the test

1. **`spur silo list` did not check the tools.** The command reads the
   profiles with `yq`, so it ended in `yq: command not found`. `list` now runs
   the same check as the other commands.
2. **The admin kubeconfig needs sudo on a node that is not the control
   plane.** `spur k8s kubeconfig --admin` as the user `ubuntu` answers `the
   cluster-admin kubeconfig requires cluster admin`, because a cluster without
   accounting knows no administrator but root. The lookup order is now:
   `--kubeconfig`, `KUBECONFIG`, `spur k8s kubeconfig --admin`, the same call
   under `sudo -n`, then `sudo -n k0s kubeconfig admin`.

## Fixed in the Go plugin, and in bootstrap.sh with it

3. **A purge deleted the namespace of a package while a later package of the
   same namespace still needed it.** `kyverno-policies-storage-local-path` goes
   first and its purge deleted the namespace `kyverno`. The next removal, the
   `kyverno` chart itself, then failed in its `pre-delete` hook with
   `jobs.batch "kyverno-scale-to-zero" is forbidden: unable to create new
   content in namespace kyverno because it is being terminated`. The same
   happened in the namespace `aim-system`. A purge now removes the releases
   first and deletes each namespace once, after the last package of that
   namespace is gone, and never a namespace that a package of another installed
   profile holds.
4. **The deletion of a CRD never ended when its CRs kept a finalizer.** The
   removal of `aim-engine-crds` stopped at the helm timeout of 10 minutes,
   because the `aim-engine` controller was already gone and no one took the
   finalizers off the AIM objects. A purge now deletes the CRs and takes their
   finalizers off before it removes the CRD, while the controller of the
   release still runs. The same removal now takes 45 seconds.
5. **The CRDs of a `crds/` directory stayed after a purge.** `helm get
   manifest` does not hold them, so `gateway.api.crds` still probed `yes` after
   an uninstall. A purge now reads the CRD names of the chart `crds/` directory
   too.

## Found on itg1 and fixed

6. **The smoke test waited out its 15 minutes on an object that had already
   failed.** The dummy AIMService names the Secret `aim-pull`, and aim-engine
   fails the model when that Secret is not in the namespace
   (`SecretNotFound: imagePullSecret "aim-pull" not found in namespace
   "aims-test"`). `byok/tests/smoke.sh` takes the reference off the object in
   that case; the Go build did not. It now copies the Secret from `aim-system`
   when the install made one, takes the reference off when there is none, and
   stops as soon as the object reports `Failed`, with the conditions that hold
   it back. The smoke test then passed on itg1 in 31 seconds.
7. **A second profile could go on top of a profile it shares packages with.**
   `install scalable-inference --no-gpu` on a node that already had
   `scalable-inference-gpu` installed both profiles: the record held both
   names, and the CPU values went over the charts of the GPU install. An
   install now stops when another recorded profile shares packages with it. An
   install of the same profile is an upgrade, and a profile that says `extends`
   the recorded one, as `aiwb-demo` does, is the documented way to add to it.
8. **The API server deprecation warning came once per request.** The client
   now prints one line per warning.

## Found on the second Kaytoo round and fixed

- **An uninstall took CRDs that a package of another profile owns.** After
  `uninstall aiwb-demo` the log said `keep gateway-api-crds, another installed
  profile holds it` and the release was still there, but `gateway.api.crds`
  probed `no`: the `envoy-gateway` chart ships the Gateway API CRDs in a
  subchart `crds/` directory, so the purge of `envoy-gateway` deleted the names
  that `gateway-api-crds` owns too. The keep list guarded releases, not CRDs. A
  purge now leaves every CRD that a package which stays ships, and says so.
- **A failing package took 36 minutes and never named the cause.** The only
  text was `context deadline exceeded`, three times over the 10 minute helm
  timeout. The real cause, `secret "aiwb-ui-keycloak-secret" not found`, was
  visible in the pods only. After a failed attempt the binary now looks for a
  pod that cannot start for a reason a retry does not change
  (`CreateContainerConfigError`, `ImagePullBackOff`, `CrashLoopBackOff` and
  the like) and stops with that pod, its reason and its message.
- **A failed install left its packages with no record.** `aiwb-demo` left 10
  releases behind and `status` named only `scalable-inference`. The install now
  writes the record of the packages that did go on and marks it partial, and
  `status` says that the install stopped and which command removes them.

- **A profile whose install stopped could not be removed.** The partial record
  of `aiwb-demo` ended at the last package that went on, so `aiwb` was never a
  removal target, but the failed helm install had left the release `aiwb/aiwb`.
  `refuseWhenNeeded` then saw `aiwb` installed, saw `dex` giving it
  `auth.oidc`, and refused at the first package: `error: aiwb is installed and
  needs auth.oidc from dex`. A package of the profile that goes away no longer
  holds that same removal back, the partial record names the failed package
  too, and a removal that reads a partial record takes the package list from
  the profile.

## Open

9. **The `aiwb` chart 2.0.0 asks for the Secret `aiwb-ui-keycloak-secret`,
   which the `aiwb-demo` profile does not make.** The `aiwb-demo-secrets`
   package makes `aiwb-oidc-client-secret`, and the chart reads the name from
   `keycloak.secretName`, whose default is `aiwb-ui-keycloak-secret`. Both
   `aiwb-api` and `aiwb-ui` stay in `CreateContainerConfigError` with
   `secret "aiwb-ui-keycloak-secret" not found`, so the install of the
   `aiwb-demo` profile never finishes. The change from Keycloak to Dex did not
   follow the name through. The profile must set `keycloak.secretName`,
   `keycloak.url`, `keycloak.internalUrl` and `keycloak.clientId` for Dex, or
   the secrets package must make the Secret under the name the chart wants,
   with the keys the chart reads with `envFrom`.
10. **aim-catalog never collects the pods of its discovery Jobs.** Ten minutes
   after the install, `aim-system` held 160 `Succeeded`
   `discover-amdenterpriseai-aim-*` pods, and new bursts follow. They hold no
   resources, but they hide the running pods of the namespace. The chart needs
   `ttlSecondsAfterFinished` on the Job.
11. **The cert-manager pods declare no requests and no limits.** All three are
   invisible to the scheduler for capacity planning.
12. **An install cannot be stopped from outside the process group.** Under
   `sudo`, a `SIGTERM` to the caller left the child running to the end. The Go
   build now cancels the helm operation on `SIGINT` and `SIGTERM` of its own
   process, which covers Ctrl-C in a terminal.
13. **The `envoy-gateway` values carry a cluster-bloom node selector.**
   `install aiwb-demo` warns `cannot overwrite table with non table for
   envoy-gateway-config.envoy-gateway-config.envoyProxy.nodeSelector
   (map[cluster-bloom/first-node:true])`. No k0s cluster has that label, and
   the profile cannot override the value.
14. **Two namespaces stay after every uninstall.** `aims-test` comes from
   `--smoke-test` and `workbench` from the `aiwb-demo` install. Both are empty.
   Neither is the namespace of a package, so the purge does not reach them.
15. **`--ref` defaults to `main`, which holds no `byok/` directory.** Every
   command needs `--ref EAI-8560-byok` until the branch merges. The error
   message names the cause: `no byok/bootstrap.sh under ...`.

## Proven

- `install scalable-inference` from the control-plane node: 93 seconds, the
  install record written, every capability probe `yes`.
- `status` from the control-plane node (kubeconfig from `k0s`) and from the
  driver node (kubeconfig from Spur over gRPC under sudo).
- `uninstall aiwb-demo` with both profiles recorded keeps every package of
  `scalable-inference` and removes only the packages of the demo.
- `uninstall scalable-inference` empties the install record.
- On two Kaytoo VMs with the Go build: `install scalable-inference` 1 min 41 s,
  `uninstall scalable-inference` 51 s with no CRD and no namespace left,
  `install scalable-inference --smoke-test` 3 min 04 s with the smoke test
  passed, `status` from both the control-plane node and the worker, and the
  error paths (a missing `--var`, an unknown profile, `--no-gpu` on a CPU
  cluster).
- On itg1, one MI300X node with 8 GPUs: `uninstall scalable-inference-gpu` in
  2 min 51 s with no CRD and no namespace left, `install scalable-inference
  --smoke-test` in 3 min 24 s with the GPU profile selected by the node GRES,
  every capability `yes`, `amd.com/gpu: 8` allocatable and the smoke test
  passed.
- `spur plugin list` marks a plugin that shadows a built-in command, and the
  built-in command wins.
