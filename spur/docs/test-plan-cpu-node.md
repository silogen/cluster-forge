# Test plan: spur-aims on CPU-only nodes

The repeatable CPU test round of the `spur aims` plugin. It applies to any
node with no GPU: a cloud VM, a bare-metal server or a local VM. It needs no
cluster-bloom. The GPU path is in
[Set up one node for a Spur Kubernetes cluster](spur-node-setup.md), and the open
results of both are in [Future work](future-work.md).

Any Spur cluster with k0s is sufficient. On Kaytoo VMs, the
`spur-kaytoo-cluster` skill makes one. This page adds only what the
`spur-aims` test needs on top of the cluster.

## 1. The cluster

Two nodes are enough: one becomes the k0s control plane, the other the worker.
Run the test from the **worker**, because that is the node that must find the
admin kubeconfig through `sudo -n spur k8s kubeconfig --admin`.

Points that cost time when they are missed:

- Open the firewall between the nodes before the daemons start. For example,
  the OCI image rejects everything but SSH.
- On a cloud network that drops packets with pod addresses, such as OCI, set
  `--overlay-type=full` and `--enable-overlay=true` in
  `/var/lib/k0s/manifests/kuberouter/kube-router.yaml` on the control-plane
  node after `spur k8s up`. Without it, pod-to-pod packets between the nodes
  are lost and the install stops in unrelated places.
- Put `allow_admin_kubeconfig = true` in the `[cluster]` section of
  `/etc/spur/spur.conf` on every node, before `spurctld` starts. The newer
  Spur builds refuse `spur k8s kubeconfig --admin` over RPC without it, and
  the worker holds no `k0s` admin file, so every plugin command fails on the
  driver node. See finding 18.
- A `spurd` that starts against a follower can end with `registration failed:
  not the Raft leader`. It does not retry. Start it again; the second try
  registers. Check with `spur nodes` that both hostnames are there before
  `spur k8s up`.
- A fresh node may hold no `kubectl`. `spur aims` does not need one, but a test that
  looks at pods does. Install it on the driver node, or read the cluster from
  the control-plane node with `sudo k0s kubectl`.

## 2. The binary

Build `spur-aims` from the branch under test and copy it to the driver
node:

```bash
just spur/all <branch>
scp spur/spur-aims/spur-aims <user>@<driver node>:/tmp/
ssh <user>@<driver node> 'sudo install -m755 /tmp/spur-aims /usr/local/bin/'
```

`spur aims version` must answer with the ref that `all` got.

## 3. The round

The nodes have no GPU, so the round uses the `-cpu` profiles through `--no-gpu`.

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
  `validate` for this check: an install of `default` on a CPU node pulls about
  80 GiB of Instinct model images through the catalog discovery pods and
  fills the disk, see the findings. If it ran, remove it again before the
  CPU round, and `spur k8s down --reset` then `spur k8s up` when the disk is
  full.
- After `install demo --no-gpu`, `aim-system` holds no accelerator detector
  DaemonSet: the `-cpu` profiles turn it off, because they hold no
  node-feature-discovery to read its result. See the findings.
- After `install demo --no-gpu`, `just smoke-ui` passes. Its step 8 checks
  that a model route gives 401 without a token. `just show-token-demo`
  prints a token and a curl example, and that curl gives HTTP 200 on a
  deployed model.
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
after the chart is packaged into `spur/packages/<name>/charts/`. Do this in a
copy of `spur/`, never in the branch, unless the chart is a released one.

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

# 3. Vendor it into a copy of spur, with the dependency version of the package.
cp -r spur /tmp/silo-test/spur
cp /tmp/pkg/<chart>-<ver>.tgz /tmp/silo-test/spur/packages/<name>/charts/
rm /tmp/silo-test/spur/packages/<name>/charts/<old>.tgz
yq -i '.dependencies[0].version = "<ver>"' /tmp/silo-test/spur/packages/<name>/{Chart.yaml,Chart.lock}
```

Then build the assets by hand, because `just assets` runs `helm dependency
build`, which tries to pull the vendored chart from the registry again:

```bash
cd /tmp/silo-test/spur/spur-aims
rm -rf assets && mkdir -p assets/tests
cp ../capabilities.yaml assets/ && cp -r ../profiles assets/profiles && cp -r ../packages assets/packages
cp ../tests/aimservice-dummy.yaml assets/tests/
find assets/packages -name Chart.lock -delete
just build <label>
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

Release the nodes when the round ends, for example delete Kaytoo VMs with the
Kaytoo tool. Delete every copy of a
registry token too.
