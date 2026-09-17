# spur-inference test findings

What the tests of the `spur inference` plugin found. Each item says where it
was found and what the state is. The Go rewrite of the plugin keeps this list
as its input.

The tests ran before the rename of 2026-09-17, when the plugin was `spur silo`
and the profiles were `inference`, `inference-gpu` and `inference-demo`. The
results keep the names of their time. The new names are `spur inference`,
`default-cpu`, `default` and `demo`, and a result that names a profile gives
the new name in brackets. `bootstrap.sh`, the bash path, is gone.

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
   `install inference --no-gpu` (now `install --no-gpu`) on a node that
   already had `inference-gpu` (now `default`) installed both profiles: the record held both
   names, and the CPU values went over the charts of the GPU install. An
   install now stops when another recorded profile shares packages with it. An
   install of the same profile is an upgrade, and a profile that says `extends`
   the recorded one, as `inference-demo` does, is the documented way to add to it.
8. **The API server deprecation warning came once per request.** The client
   now prints one line per warning.

## Found on the second Kaytoo round and fixed

- **An uninstall took CRDs that a package of another profile owns.** After
  `uninstall inference-demo` the log said `keep gateway-api-crds, another installed
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
- **A failed install left its packages with no record.** `inference-demo` left 10
  releases behind and `status` named only `inference`. The install now
  writes the record of the packages that did go on and marks it partial, and
  `status` says that the install stopped and which command removes them.

- **A profile whose install stopped could not be removed.** The partial record
  of `inference-demo` ended at the last package that went on, so `aiwb` was never a
  removal target, but the failed helm install had left the release `aiwb/aiwb`.
  `refuseWhenNeeded` then saw `aiwb` installed, saw `dex` giving it
  `auth.oidc`, and refused at the first package: `error: aiwb is installed and
  needs auth.oidc from dex`. A package of the profile that goes away no longer
  holds that same removal back, the partial record names the failed package
  too, and a removal that reads a partial record takes the package list from
  the profile.

## Open

- **The Radeon warning is untested on a node.** The rename of 2026-09-17
  replaced the Instinct auto-selection with a warning for a GPU that is not
  Instinct, from the `gpu:` type of `spur show node`. No node with a Radeon
  card was available, so the table test of `kube_test.go` is the only check.
- **The CPU detector of the `-cpu` profiles runs, but its labels reach no
  node.** On the Kaytoo round of 2026-09-17 the DaemonSet
  `aim-engine-aim-engine-chart-accelerator-detector-cpu` came to 1/1 in
  `aim-system`, from the image `amdenterpriseai/aim-epyc-base:0.11` (1.8 GiB).
  It reports `type=CPU model=CPU count=1` and writes
  `feature.node.kubernetes.io/aim-accelerator.CPU=1` to
  `/etc/kubernetes/node-feature-discovery/features.d/aim-accelerator-cpu` on
  the node, not an `EPYC_*` label. Nothing reads that file: node-feature-
  discovery comes with the AMD GPU operator, which the `-cpu` profiles do not
  hold, so the node never gets the label. The dummy model served without the
  label in every earlier round. Decided on 2026-09-17: the `-cpu` profiles
  turn the detector off again, as the profiles before the rename did. A `-cpu`
  profile with node-feature-discovery is future work.
- **A `default` install on a cluster with no GPU fills the disk.** The
  warning of `install` is right, but it does not say what follows: the
  catalog of the `default` profile discovers every Instinct model, and each
  discovery pod pulls a model image of about 10 GiB. On a Kaytoo VM with a
  96 GiB disk the worker pulled about 80 GiB in 25 minutes, the I/O pressure
  of the node stayed above 50 %, and the kubelet could stop no pod sandbox.
  The blank-name `uninstall --yes` then timed out after 10 minutes in the
  pre-delete hook Job of `amd-gpu-operator`, whose finished pod could not be
  stopped. A restart of the k0s worker, a force delete of the terminating
  discovery pods and a `ctr leases rm --sync` freed the disk, and the retried
  uninstall resumed in 47 seconds: it skipped the seven packages that the
  first run had removed and purged the rest. Two things to do: the warning
  should name the image pulls, and the discovery pods of the catalog should
  not pull an image at all on a node with no GPU (item 10 is related).
- **An uninstall that stopped part way left the namespaces of the packages
  it had removed.** Fixed on 2026-09-17: the purge now deletes the namespace
  of a skipped package too, unless a package that stays holds it.

9. **The `aiwb` chart 2.0.0 asks for the Secret `aiwb-ui-keycloak-secret`,
   which the `inference-demo` profile does not make.** The `aiwb-demo-secrets`
   package makes `aiwb-oidc-client-secret`, and the chart reads the name from
   `keycloak.secretName`, whose default is `aiwb-ui-keycloak-secret`. Both
   `aiwb-api` and `aiwb-ui` stay in `CreateContainerConfigError` with
   `secret "aiwb-ui-keycloak-secret" not found`, so the install of the
   `inference-demo` profile never finishes. The change from Keycloak to Dex did not
   follow the name through.

   The `aiwb` package values already give the whole `oidc` block
   (`internalUrl`, `jwksUrl`, `clientId`, `secretName: aiwb-oidc-client-secret`,
   `audience`) and `openBao.enabled: false`, and the profile gives
   `oidc.issuer`. Chart 2.0.0 knows neither key, so it ignores both and reads
   `keycloak.secretName`. The package is written for a chart that does not
   exist yet.

   Two open pull requests in silogen/core make that chart, and the demo needs
   both:

   - silogen/core#4643 (`EAI-8694: Let AIWB log in through any OIDC issuer`)
     adds the `oidc` block. `oidc.secretName` gives the Secret name,
     `oidc.issuer`, `oidc.internalUrl`, `oidc.clientId` and `oidc.jwksUrl` give
     the issuer, and the API no longer reads the client secret at all. An empty
     `oidc` block keeps the Keycloak defaults.
   - silogen/core#4642 (`EAI-8693: Make the OpenBao API-key store optional in
     the aiwb chart`) adds `openBao.enabled`. Chart 2.0.0 holds no OpenBao, but
     the chart on `main` holds it and asks for the Secret
     `aiwb-openbao-token`, which the demo does not make either. Without this
     pull request the next chart trades one missing Secret for another.

   So the profile and the package need no change. The fix is to vendor the
   `aiwb` chart from a build that holds both changes, that is, after both pull
   requests go in.

   **Proved on Kaytoo, 2026-09-16.** A chart packaged from the two branches
   merged (`aiwb-chart-2.1.0-oidc-openbao`), with the images
   `silogenai/aiwb-{api,ui}:EAI-8694-feat-generic-oidc`, installed the
   `inference-demo` profile twice on a two-node k0s cluster. Both times the install
   said `install finished` and `aiwb-api` and `aiwb-ui` came to `1/1 Running`;
   the second round took 37 seconds for the two pods. No Deployment names
   `aiwb-ui-keycloak-secret` any more: the UI takes `OIDC_CLIENT_SECRET` from
   `aiwb-oidc-client-secret/value`, the API takes no client secret, and
   `OPENBAO_ADDR` is empty. The UI reads the Dex discovery document and the API
   reads the Dex JWKS (1 key) from inside the cluster. `uninstall inference-demo`
   then removed the profile in 1 minute 25 seconds. The images are in the
   private `silogenai` repository, so the test needed a pull secret; the
   released chart takes the images from `amdenterpriseai`.

   **Closed on 2026-09-17**, with a chart packaged from core#4643 at
   `7c5eab912` (it holds core#4642, which is merged). The `demo` install
   finished, and a browser login through Dex gave a session and a token the
   API accepts. See the round of 2026-09-17 with that chart.

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
   `install inference-demo` warns `cannot overwrite table with non table for
   envoy-gateway-config.envoy-gateway-config.envoyProxy.nodeSelector
   (map[cluster-bloom/first-node:true])`. No k0s cluster has that label, and
   the profile cannot override the value.
14. **Two namespaces stay after every uninstall.** `aims-test` comes from
   `--smoke-test` and `workbench` from the `inference-demo` install. Both are empty.
   Neither is the namespace of a package, so the purge does not reach them.
15. **The skill command `spur admin raft status` does not exist.** The spur
   CLI of `main` at `467d521` has no `admin` command, so the Raft health check
   of the Kaytoo skill cannot be run. The plugin work did not remove it; the
   skill names a command that this version never had. Read the health from
   `spur nodes` instead.
16. **The CRD keep of an uninstall is wider than it needs to be.** Removing
   `envoy-gateway` kept its own eight `gateway.envoyproxy.io` CRDs, because a
   package that stays ships the same names in its chart. Nothing that stays
   uses that API group, so the CRDs only go later, with the base profile. The
   end state is right and no object is lost; the keep decision reads the chart
   names, not the live owners.
17. **`--ref` defaults to `main`, which holds no `byok/` directory.** Every
   command needs `--ref EAI-8560-byok` until the branch merges. The error
   message names the cause: `no byok/bootstrap.sh under ...`.

## Kaytoo round of 2026-09-17, after the rename

Two Kaytoo VMs, Spur 0.12.0 from `feat/cli-plugins` (6fad5b9), k0s
v1.36.2+k0s.0, control plane `useocpm2m-silogen-petrus-3k9y7q`, worker and
driver node `useocpm2m-silogen-petrus-uuxd3p`. Binary built from
`EAI-8560-byok` at the rename.

- `spur inference version` and `spur inference list` answer through the
  plugin mechanism; `list` shows `default`, `default-cpu`, `demo`, `demo-cpu`
  and `test-s3`.
- `spur show node` on the VMs prints no `Gres=` line at all. `validate`,
  `validate --no-gpu` and `validate demo --no-gpu` pass; the first prints the
  warning that Spur reports no GPU and that `default` installs the GPU
  operator, the two `-cpu` runs print no warning.
- `install` with no name went on in 2 min 06 s with the warning first, the
  GPU operator included, on a cluster with no GPU. The disk finding above
  followed; the retried blank-name `uninstall --yes` took 47 s.
- After `spur k8s down --reset` and `spur k8s up`: `install demo --no-gpu`
  with the three variables put 17 of 18 packages on in about 3 minutes and
  stopped at `aiwb` after 10 min 53 s with the message
  `pod aiwb/aiwb-api-... is in CreateContainerConfigError: secret
  "aiwb-ui-keycloak-secret" not found`. That is item 9: core#4642 is merged,
  core#4643 is still open, so the vendored chart is still 2.0.0. `status`
  reports the partial record and names the command that removes it.
- `uninstall` with no name on a terminal printed the plan of `demo-cpu`, 17
  packages with the failed `aiwb` release first and ten namespaces, and asked
  `Remove? [y/N]`. After `n` nothing went away and the record still held the
  profile. After `y` the profile was gone in 86 s: no profile recorded, no
  CRD, no PVC, and only the empty namespace `inference-system` left.
- `uninstall` from a pipe without `--yes` refuses before it connects.
- The test-s3 cycle, the smoke tests and the Radeon warning did not run.


## Kaytoo round of 2026-09-17, with the aiwb chart of core#4643

Two Kaytoo VMs, the same evening as the round above. Spur 0.12.0 from
`feat/cli-plugins` (6fad5b9), k0s v1.36.2+k0s.0, control plane
`useocpm2m-silogen-petrus-cn54bb` (10.0.255.200), worker and driver node
`useocpm2m-silogen-petrus-y2rm5z` (10.0.255.6). The binary holds the chart
`aiwb-chart-2.1.0-oidc`, packaged from core#4643 at `7c5eab912`, with the
images `silogenai/aiwb-{api,ui}:EAI-8694-feat-generic-oidc` and the pull
secret `aiwb-pull`. core#4642 is merged, so the branch alone gives both
changes.

### Item 9 is closed: AIWB logs in through Dex

`install demo --no-gpu` put all 18 packages on in 3 min 27 s. `aiwb-api` and
`aiwb-ui` came to `1/1 Running`. No object names `aiwb-ui-keycloak-secret`.
The API takes no client secret, the UI takes `OIDC_CLIENT_SECRET` from
`aiwb-oidc-client-secret/value`, `OPENBAO_ADDR` has no value, and the OIDC
environment holds `OIDC_ISSUER=https://auth.<domain>`,
`OIDC_ISSUER_INTERNAL_URL=http://dex.dex.svc.cluster.local:5556`,
`OIDC_JWKS_URL=.../keys`, `OIDC_CLIENT_ID=aiwb` and `OIDC_AUDIENCE=aiwb`.

The login was tested end to end through the gateway, not only from the
manifests:

- The UI answers `307` to `/api/auth/signin?callbackUrl=%2F`, and its only
  provider is `oidc`.
- The Dex discovery document answers on the public domain and names the
  issuer, the authorization endpoint and the JWKS URL.
- A `curl` login (CSRF token, NextAuth signin, the Dex form, the callback)
  ends with a session for `devuser@<domain>`.
- The API answers `401` to `/v1/inference/models` with no token and `200`
  with an `id_token` that Dex issued for the client `aiwb`.

### The smoke test and the test-s3 cycle, which were open

- `install --no-gpu --smoke-test`: 6 min 22 s, the smoke test passed. The
  Secret `aim-pull` is not in `aims-test`, so the reference goes off the
  dummy object, as item 6 describes.
- The test-s3 cycle by hand: `install default-cpu` 2 min 25 s, `install
  test-s3` 1 min 21 s, the five seaweedfs pods `Ready`, `storage.s3` and
  `storage.s3.operator` both `yes`. `uninstall test-s3 --yes` took 18 s, kept
  the nine packages of `default-cpu` and removed only the two seaweedfs
  packages and their namespaces. The idempotence step of
  `tests/optional-package-cycle.sh` did not run, because the VMs hold no helm
  and no yq.

### The rest of the round

- `validate` prints the no-GPU warning, `validate --no-gpu` and `validate
  demo --no-gpu` pass with no warning. `spur show node` prints no `Gres=`
  line.
- The error paths answer as they must: a missing `--var`, an unknown
  profile, `install default-cpu --no-gpu`, and `uninstall` from a pipe with
  no `--yes`.
- `install default` over an installed `default-cpu` refuses and names the
  nine shared packages.
- `spur plugin list` marks a `spur-nodes` binary as shadowed, and the
  built-in `nodes` wins.
- `uninstall demo-cpu --yes`: 20 s, every package of `default-cpu` kept, and
  the Gateway API and Envoy CRDs kept because a package that stays ships the
  same names (item 16).
- `uninstall` on a terminal: after `n` nothing went away and the record still
  held `default-cpu`; after `y` the profile was gone. The end state holds no
  profile, no PVC, and only the five CRDs of k0s itself. The namespaces
  `aims-test` and `inference-system` stay, as item 14 describes.
- Item 13 is still there: the `envoy-gateway-config` values carry the
  cluster-bloom node selector and the install warns about it.

### 18. The admin kubeconfig over RPC is now off by default

`sudo -n spur k8s kubeconfig --admin` on the worker answers `serving the
cluster-admin kubeconfig over RPC is disabled ([cluster]
allow_admin_kubeconfig = false)`. The lookup order of item 2 then has nothing
left on a worker, because a worker holds no `/var/lib/k0s/pki/admin.conf`, so
every plugin command fails there. Put `allow_admin_kubeconfig = true` in the
`[cluster]` section of `/etc/spur/spur.conf` on every node before `spurctld`
starts, or drive the test from the control-plane node. With the option set,
the plugin reports `admin kubeconfig from sudo -n /usr/local/bin/spur k8s
kubeconfig --admin` and every command works from the worker.

### 19. A `pkill -f "spurd --controller"` over SSH kills the caller

The pattern matches the remote shell command itself, so the restart of a
`spurd` that failed with `not the Raft leader` kills the SSH command before
it starts the daemon again, and the log keeps its old content. Use `pkill -x
spurd`. The registration of the second node needed two tries in this round
too.
## Proven

- `install inference` (now `default-cpu`) from the control-plane node: 93
  seconds, the install record written, every capability probe `yes`.
- `status` from the control-plane node (kubeconfig from `k0s`) and from the
  driver node (kubeconfig from Spur over gRPC under sudo).
- `uninstall inference-demo` (now `demo-cpu`) with both profiles recorded keeps
  every package of `inference` (now `default-cpu`) and removes only the
  packages of the demo.
- `uninstall inference` (now `default-cpu`) empties the install record.
- The last Kaytoo round, with every fix in: `uninstall inference-demo` (now
  `demo-cpu`) after a failed install removes the failed `aiwb` release first,
  keeps all nine packages of `inference` (now `default-cpu`) and twenty CRDs,
  and takes 20 seconds. The
  `aiwb` failure itself reports in 10 min 53 s and names the pod and the
  missing Secret. The end state holds no CRD, no record and only the namespace
  `aims-test` of the smoke test.
- On two Kaytoo VMs with the Go build: `install inference` (now
  `default-cpu`) 1 min 41 s, `uninstall inference` 51 s with no CRD and no
  namespace left, `install inference --smoke-test` 3 min 04 s with the smoke
  test passed, `status` from both the control-plane node and the worker, and
  the error paths (a missing `--var`, an unknown profile, `--no-gpu` on a CPU
  cluster).
- On itg1, one MI300X node with 8 GPUs: `uninstall inference-gpu` (now
  `default`) in 2 min 51 s with no CRD and no namespace left, `install
  inference --smoke-test` in 3 min 24 s with the GPU profile selected by the
  node GRES (the plugin no longer selects a profile; `default` is the GPU
  profile), every capability `yes`, `amd.com/gpu: 8` allocatable and the
  smoke test passed.
- `spur plugin list` marks a plugin that shadows a built-in command, and the
  built-in command wins.
