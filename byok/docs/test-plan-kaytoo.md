# Test plan: spur-aims on Kaytoo VMs

The repeatable CPU test round of the `spur aims` plugin. It needs no GPU and no
cluster-bloom. The GPU path has its own plan in
[Test plan: byok on a GPU node](test-plan-gpu.md), and the results of both are
in [spur-aims test findings](spur-aims-findings.md).

The cluster itself comes from the `spur-kaytoo-cluster` skill. This page adds
only what the `spur-aims` test needs on top of it.

## 1. The cluster

Two VMs are enough: one becomes the k0s control plane, the other the worker.
Run the test from the **worker**, because that is the node that must find the
admin kubeconfig through `sudo -n spur k8s kubeconfig --admin`.

Points that cost time when they are missed:

- Open the firewall on both VMs before the daemons start. The OCI image rejects
  everything but SSH.
- After `spur k8s up`, set `--overlay-type=full` and `--enable-overlay=true` in
  `/var/lib/k0s/manifests/kuberouter/kube-router.yaml` on the control-plane
  node. Without it OCI drops pod-to-pod packets between the nodes and the
  install stops in unrelated places.
- Put `allow_admin_kubeconfig = true` in the `[cluster]` section of
  `/etc/spur/spur.conf` on every node, before `spurctld` starts. The newer
  Spur builds refuse `spur k8s kubeconfig --admin` over RPC without it, and
  the worker holds no `k0s` admin file, so every plugin command fails on the
  driver node. See finding 18.
- A `spurd` that starts against a follower can end with `registration failed:
  not the Raft leader`. It does not retry. Start it again; the second try
  registers. Check with `spur nodes` that both hostnames are there before
  `spur k8s up`.
- The VMs hold no `kubectl`. `spur aims` does not need one, but a test that
  looks at pods does. Install it on the driver node, or read the cluster from
  the control-plane node with `sudo k0s kubectl`.

## 2. The binary

Build `spur-aims` from the branch under test and copy it to the driver
node:

```bash
make -C byok/spur-aims all REF=<branch>
scp byok/spur-aims/spur-aims ubuntu@<driver public ip>:/tmp/
ssh ubuntu@<driver public ip> 'sudo install -m755 /tmp/spur-aims /usr/local/bin/'
```

`spur aims version` must answer with the ref that `REF` gave.

## 3. The round

The VMs have no GPU, so the round uses the `-cpu` profiles through `--no-gpu`.

```bash
spur aims list
spur aims install                  # warns: no GPU, the default profile installs the GPU operator
spur aims uninstall --yes
spur aims validate --no-gpu        # validates default-cpu
spur aims validate demo --no-gpu --var domain=<ip>.nip.io   # validates demo-cpu
spur aims install --no-gpu --smoke-test
spur aims status
spur aims install demo --no-gpu --var domain=<ip>.nip.io \
                    --var gatewayServiceType=ClusterIP --var gatewayExternalIP=<node ip>
spur aims uninstall demo-cpu --yes     # the base profile and its CRDs must stay
spur aims uninstall                    # shows the plan and asks; answer n, then y
spur aims status                       # no profile is recorded
```

With no load balancer, give `gatewayServiceType=ClusterIP` and
`gatewayExternalIP=<node private ip>`. The domain only has to resolve for a
browser test; `<private ip>.nip.io` is enough for an install.

Checks of the round:

- `install` with no name and no `--no-gpu` prints the warning that Spur
  reports no GPU and that the profile installs the GPU operator. Prefer
  `validate` for this check: an install of `default` on a VM pulls about
  80 GiB of Instinct model images through the catalog discovery pods and
  fills the disk, see the findings. If it ran, remove it again before the
  CPU round, and `spur k8s down --reset` then `spur k8s up` when the disk is
  full.
- After `install demo --no-gpu`, `aim-system` holds no accelerator detector
  DaemonSet: the `-cpu` profiles turn it off, because they hold no
  node-feature-discovery to read its result. See the findings.
- `install demo --no-gpu` stops at `aiwb` with `secret
  "aiwb-ui-keycloak-secret" not found` until the aiwb chart of core#4643 is
  vendored (finding 9). The 17 packages before it are the test of the
  profile until then.
- `uninstall` with no name and no `--yes` shows the plan and asks. After `n`
  nothing went away; after `y`, `status` reports no profile.
- On a node with a Radeon card, when one is available: `spur show node` shows
  a `gpu:` type that is not `mi` plus digits, and both `validate` and
  `validate --no-gpu` print the warning that names the node and the type.
  When no such node is available, the table test of `kube_test.go` is the
  only check, and the findings say so.

`uninstall` asks `Remove? [y/N]` on a terminal. `--yes` skips the question,
and a run whose stdin is not a terminal needs it.

Error paths to try in the same round: a missing `--var`, an unknown profile,
`install --no-gpu` over an installed `default` (it must refuse and name the
shared packages), `install default-cpu --no-gpu` (refused, the name already
ends with `-cpu`), and `spur plugin list` with a shadowing binary.

## 4. A chart that is not released yet

The binary holds the charts, so a chart fix in silogen/core reaches a test only
after the chart is packaged into `byok/packages/<name>/charts/`. Do this in a
copy of `byok/`, never in the branch, unless the chart is a released one.

```bash
# 1. A worktree of core with the branches of the pull requests merged.
git worktree add -b <temp> <dir> origin/<branch-a> && git -C <dir> merge origin/<branch-b>

# 2. Package as the release workflow does: the OCI name takes a "-chart" suffix,
#    and an empty image tag takes the release tag.
cp -r <dir>/helm/<chart> /tmp/pkg && cd /tmp/pkg
yq -i '.version = "<ver>" | .appVersion = "<image tag>"' Chart.yaml
yq -i '(.. | select(tag == "!!map" and has("tag") and .tag == "")) |= .tag = "<image tag>"' values.yaml
yq -i '.name = .name + "-chart"' Chart.yaml
helm package .

# 3. Vendor it into a copy of byok, with the dependency version of the package.
cp -r byok /tmp/silo-test/byok
cp /tmp/pkg/<chart>-<ver>.tgz /tmp/silo-test/byok/packages/<name>/charts/
rm /tmp/silo-test/byok/packages/<name>/charts/<old>.tgz
yq -i '.dependencies[0].version = "<ver>"' /tmp/silo-test/byok/packages/<name>/{Chart.yaml,Chart.lock}
```

Then build the assets by hand, because `make assets` runs `helm dependency
build`, which tries to pull the vendored chart from the registry again:

```bash
cd /tmp/silo-test/byok/spur-aims
rm -rf assets && mkdir -p assets/tests
cp ../capabilities.yaml assets/ && cp -r ../profiles assets/profiles && cp -r ../packages assets/packages
cp ../tests/aimservice-dummy.yaml assets/tests/
find assets/packages -name Chart.lock -delete
make build REF=<label>
```

Render the chart once with `helm template` before the cluster round. It costs
seconds and finds a missing Secret or a wrong image name before an install
takes twenty minutes.

Images built from a pull-request branch are in the private `silogenai`
repository, not in `amdenterpriseai`, and their tag is the branch name. Point
the package values at them and give an `imagePullSecrets` name, then make that
Secret as soon as the namespace exists:

```bash
until kubectl get ns <ns> >/dev/null 2>&1; do sleep 10; done
kubectl -n <ns> create secret docker-registry <name> \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<user> --docker-password="$(cat <token file>)"
```

The kubelet retries the pull, so the Secret may appear after the Deployment.
The Docker Hub credentials of the team are in `/etc/bloom/bloom.yaml` on a
node that cluster-bloom installed. Never print them.

## 5. Clean up

Delete the VMs with the Kaytoo tool when the round ends. Delete every copy of a
registry token too.
