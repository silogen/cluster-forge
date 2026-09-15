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

4. **A purge deleted the namespace of a package while a later package of the
   same namespace still needed it.** `kyverno-policies-storage-local-path` goes
   first and its purge deleted the namespace `kyverno`. The next removal, the
   `kyverno` chart itself, then failed in its `pre-delete` hook with
   `jobs.batch "kyverno-scale-to-zero" is forbidden: unable to create new
   content in namespace kyverno because it is being terminated`. The same
   happened in the namespace `aim-system`. A purge now removes the releases
   first and deletes each namespace once, after the last package of that
   namespace is gone, and never a namespace that a package of another installed
   profile holds.
5. **The deletion of a CRD never ended when its CRs kept a finalizer.** The
   removal of `aim-engine-crds` stopped at the helm timeout of 10 minutes,
   because the `aim-engine` controller was already gone and no one took the
   finalizers off the AIM objects. A purge now deletes the CRs and takes their
   finalizers off before it removes the CRD, while the controller of the
   release still runs. The same removal now takes 45 seconds.
6. **The CRDs of a `crds/` directory stayed after a purge.** `helm get
   manifest` does not hold them, so `gateway.api.crds` still probed `yes` after
   an uninstall. A purge now reads the CRD names of the chart `crds/` directory
   too.

## Open

3. **The `aiwb` chart 2.0.0 asks for the Secret `aiwb-ui-keycloak-secret`,
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
7. **`--ref` defaults to `main`, which holds no `byok/` directory.** Every
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
- `spur plugin list` marks a plugin that shadows a built-in command, and the
  built-in command wins.
