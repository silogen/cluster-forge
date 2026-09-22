# Plan: rename the spur-silo plugin to spur-inference

Superseded in part: the plugin is now named `aims`, not `inference`. Read
`inference` as `aims` and `spur inference` as `spur aims` everywhere below.

Status: agreed with the user on 2026-09-17, reviewed and corrected the same
day. Not started.
Branch: EAI-8560-byok. Worktree:
`/home/prepo/dev/silo/cluster-forge/.worktrees/EAI-8560-byok`.

This plan gives the decisions and the steps. Read it fully before you start.
Each decision has the reason with it, because the reason tells you what to do
when a detail of the plan does not fit the code.

The branch is work in progress. Nothing under `byok/spur-silo/` exists on
`main`, and no installation of it exists on any cluster. So no commit of this
plan is a breaking change: no `!` after the type, no `BREAKING CHANGE` note.
Do not rewrite the commits that are already pushed.

## 1. What changes

The plugin is named `inference`, not `silo`. Spur finds a plugin from the name
of its binary, so `spur inference ...` needs a binary `spur-inference`. The
name `inference` is not a built-in command or an alias of the Spur CLI
(checked in `crates/spur-cli/src/main.rs` of ROCm/spur on 2026-09-17).

| Before | After |
|---|---|
| `spur silo install inference` | `spur inference install` (blank name is `default`) |
| `spur silo install inference-gpu` | `spur inference install default` |
| `spur silo install inference` (CPU) | `spur inference install default-cpu` |
| `spur silo install inference-demo` | `spur inference install demo` |
| (did not exist) | `spur inference install demo-cpu` |
| `spur silo uninstall <name>` | `spur inference uninstall [<name>] [--yes]`, blank name is every profile |
| directory `byok/spur-silo/` | `byok/spur-inference/` |
| binary `spur-silo` | `spur-inference` |
| module `.../byok/spur-silo` | `.../byok/spur-inference` |
| namespace `silo-system` | `inference-system` |
| capability `secrets.inference-demo` | `secrets.demo` |

The default profile now holds the AMD GPU operator. A cluster with no GPU
needs the `-cpu` profile.

## 2. Decisions and their reasons

**D1. The blank profile name is `default` for `install` and `validate`.**
`main.go` refuses a blank name today, in three places (lines 64 to 76). Fill
the name once, before the command switch, so that `install` and `validate`
agree. `uninstall` is different, see D13.

**D2. The default profile is the GPU profile.** The file `default.yaml` is
the current `inference-gpu.yaml`. The file `default-cpu.yaml` is the current
`inference.yaml` plus the detector block of D6.

**D3. There is no GPU auto-selection, only a warning.** Delete the block in
`cmdInstall` (`main.go:301`) that looks at the nodes and changes the profile
name. The auto-selection existed because the default was CPU and the GPU case
had to be found. The default is now GPU, so "no GPU" is a choice that the
operator makes.

Keep the node scan of `instinctNodes` (`kube.go:118`), but make it classify
every GPU it sees, not only Instinct. Rename it `gpuNodes` and let it return,
for each node that has a `gpu:` entry on the `Gres=` line of `spur show node`,
the node name and the GPU type string. `hasInstinct` becomes a classifier of
one type string with three answers: Instinct, other AMD GPU, none.

Spur names the type in `crates/spur-devices/src/cdi/discovery.rs` of
ROCm/spur (checked 2026-09-17): an Instinct card is `mi` plus digits
(`mi100`, `mi210`, `mi250x`, `mi300a`, `mi300x`, `mi308x`, `mi325x`,
`mi350x`, `mi355x`), a Radeon RX 9000 card is `rx9070`, `rx9070xt` or
`rx9060`, and any other AMD GPU is `amdgpu-0x<device id>` or the lowercased
product name with hyphens. Do not keep a Radeon list in the plugin. The rule
is the negative one: a `gpu:` entry whose type does not start with `mi` and a
digit is an AMD GPU that is not Instinct. That covers RX 9000, older Radeon
and every card that Spur does not know yet.

The scan runs for `install` and for `validate`, after the profile name is
final (D1 and D4), so an operator can see the warning without an install. It
gives one warning in three cases:

1. The name ends with `-cpu` and the cluster has Instinct nodes: the GPUs
   will not be used.
2. The name does not end with `-cpu` and the cluster has no GPU at all: the
   profile installs the GPU operator and the GPU detector, and a cluster with
   no GPU needs `--no-gpu`. This is the case that D7 worries about: the
   install succeeds and the model gets no accelerator.
3. The cluster has a GPU that is not Instinct, with any profile name: name
   the node and the type, say that the GPU profile supports Instinct only,
   and say that the `-cpu` profile is the supported choice on this node. Add
   that the node-feature-discovery rule of the GPU operator labels such a
   node as an AMD GPU node too, so on the GPU profile the Instinct detector
   schedules onto it, and what it reports there is untested.

The warning never changes the name. Do not refuse the install in any of the
three cases: the operator may know more than the scan, for example a node
that Spur has not registered yet.

**D4. `--no-gpu` adds `-cpu` to the profile name.** One line:
`name += "-cpu"`. `parseArgs` accepts the flag for every command, so apply the
suffix in the same place as D1, before the command switch. Then
`validate demo --no-gpu` validates `demo-cpu` and not `demo`. When the name
already ends with `-cpu`, refuse the flag with a clear message. When the result
has no profile file, the usual "no such profile" error is correct.

**D5. The CPU profiles are full copies, not `extends` children.** Four profile
files, all standalone in their package list:

- `default.yaml` - the current `inference-gpu.yaml`
- `default-cpu.yaml` - the current `inference.yaml`
- `demo.yaml` - the current `inference-demo.yaml`, `extends: default`
- `demo-cpu.yaml` - a copy of `demo.yaml`, `extends: default-cpu`

Reason: `extends` cannot remove a package from the base list, and
`mergeProfiles` (`assets.go:119`) puts a package that only the child holds at
the end of the list. The AMD GPU operator must install before `aim-engine`,
because the accelerator detector reads the node labels that
node-feature-discovery writes. A CPU profile made by subtraction, or by
`extends` plus a new remove mechanism, needs about 20 lines of new merge code
that runs on every install. The repository already made this same decision
once: `inference-gpu.yaml` is a full copy for the same ordering reason, and
its header comment says so. Copy the files, do not extend the merge.

**D6. The difference between a profile and its `-cpu` twin is exactly three
things.** Nothing else may differ:

1. The packages `amd-gpu-operator` and `amd-gpu-operator-config` are absent
   from the `-cpu` profile.
2. `aim-catalog` has `hardwareFamilies: [epyc]`, not `[instinct]`.
3. `aim-engine` has `acceleratorDetector.cpu.enable: true` in the `-cpu`
   profile. The GPU profile holds `false`, because the CPU detector DaemonSet
   has no node affinity (only an optional `nodeSelector`, see
   `templates/accelerator-detector.yaml` of the chart), it reports
   `model=CPU count=1` on a GPU node and its startup probe never passes.

Both profiles hold `acceleratorDetector.enable: true`. This is a behaviour
change for the CPU profile, not a rename: `packages/aim-engine/values.yaml`
sets `acceleratorDetector.enable: false` and the current `inference.yaml`
overrides nothing, so no detector runs on a CPU install today. The CPU detector
has not run in any recorded test. Section 7 tests it on a Kaytoo VM. If the
CPU detector does not come up on a CPU node, set `enable: false` in both
`-cpu` profiles, change this decision and the test of D11, and write the
finding in `docs/spur-inference-findings.md`.

**D7. `demo.yaml` keeps the accelerator detector on.** Today
`inference-demo.yaml` sets `acceleratorDetector.enable: false`, together with
`crd.enable: false` and `clusterRuntimeConfig.enable: false`. Only the last
two are needed, because the `aiwb` chart owns the `AIMClusterRuntimeConfig`
object. The detector must stay on, or a GPU demo installs but the model gets
no accelerator, and the fault shows only when somebody deploys a model.

`mergeProfiles` replaces a package entry as a whole: a child entry with the
same name takes the place of the base entry, it does not merge into it
(`assets.go:136`). So the `aim-engine` entry of `demo.yaml` must hold every
value of the `aim-engine` entry of `default.yaml`, plus exactly these three:
`crd.enable: false`, `clusterRuntimeConfig.enable: false` and
`scaleFromZero.gatewayMetricsCollector.enable: false`. `demo-cpu.yaml` holds
the `aim-engine` entry of `default-cpu.yaml` plus the same three. The test of
D11 guards this seam too.

**D8. There is no migration from `silo-system`.** The install record moves to
the namespace `inference-system`, with no fallback read of the old namespace.
No installation of this exists anywhere, so there is nothing to migrate.

**D9. The bash path is deleted.** Delete `byok/spur/spur-silo` and
`byok/bootstrap.sh`. ADR-0002 rejected the bash path already. Two
implementations of the same install means that one of them decays without
anybody seeing it. See section 5, because three test scripts and one GitHub
workflow call `bootstrap.sh` and need work before you delete it.

**D10. The ADR files are rewritten, not added to.** Rewrite the text of
ADR-0001 and ADR-0002 with the new names. Rename the files
(`0001-spur-inference-as-plugin.md`,
`0002-spur-inference-as-a-go-binary.md`), keep the numbers. The old text stays
in the git history. Do not make an ADR-0003 for the rename.

**D11. A test guards the duplication.** The copies in D5 can drift apart, and
the drift shows only at install time. Write `profiles_test.go` in the plugin
directory. It reads the four files from `../profiles`, the source in git, not
from the embedded copy, so the test does not need `make assets`. It asserts:

- For the pairs (`default`, `default-cpu`) and (`demo`, `demo-cpu`): the
  package lists are equal after the two GPU packages are taken out of the GPU
  profile, `hardwareFamilies` is `[instinct]` against `[epyc]`,
  `acceleratorDetector.cpu.enable` is `false` against `true`, and
  `acceleratorDetector.enable` is `true` in both.
- For the pairs (`default`, `demo`) and (`default-cpu`, `demo-cpu`): the
  `aim-engine` values of the child are the `aim-engine` values of the base
  plus exactly the three keys of D7.

About 50 lines. It must not add code that runs at install time.

**D12. The no-cluster tests become Go tests.** See section 5.

**D13. `uninstall` confirms first, and a blank name means every profile.**
Two rules, agreed with the user on 2026-09-17:

1. `uninstall` destroys nothing before it has shown what goes and has received
   a yes. It prints the profile names, the packages in removal order, the
   packages that stay because another profile holds them, and the namespaces
   that the purge deletes. Then it asks `Remove? [y/N]` on stdin. `--yes`
   skips the question, for scripts and tests. When stdin is not a terminal and
   `--yes` is absent, refuse with a message that names the flag. Do not read a
   pipe as a yes.
2. `spur inference uninstall` with no name removes every recorded profile,
   with all data. `--keep-data` keeps the PVCs and the CRDs, as today. A
   profile that `extends` a recorded profile goes before its base, so the
   order is: every recorded profile whose `extends` names another recorded
   profile first, then the rest. The loop calls the removal of one profile for
   each name, and the existing "keep, another installed profile holds it"
   logic then does the right thing for the base. When nothing is recorded,
   say `No profile is recorded on this cluster.` and stop with exit code 0.

The confirmation is one question for the whole run, before the first removal.
Build the plan of every profile first, print it once, ask once.

## 3. The commits

Five commits, each one revertible alone. Use the commit message rules of
`~/.claude/CLAUDE.md`: conventional type, verb with a capital letter, title at
most 72 characters, body lines at most 80. None of them is a breaking change,
see the note at the top.

**C1 `refactor`: Rename the profiles to default and demo**

Pure data plus the strings that name it. It goes first, so that C3 ports the
tests to the final names and not to names that C1 would change again.

- `git mv profiles/inference-gpu.yaml profiles/default.yaml`
- `git mv profiles/inference.yaml profiles/default-cpu.yaml`
- `git mv profiles/inference-demo.yaml profiles/demo.yaml`, `extends: default`
- The `name:` key inside each file, and the header comments that name a
  profile
- `capabilities.yaml`: `secrets.inference-demo` becomes `secrets.demo`. The
  package `aiwb-demo-secrets` keeps its name, because it holds the chart of
  `sources/aiwb-demo-secrets`.
- `packages/*/package.yaml`: every `provides`/`requires` that names the old
  capability (`aiwb`, `aiwb-demo-secrets`, `postgres`, `dex`), and the
  `description` of `packages/aiwb-demo-secrets/Chart.yaml`
- `spur-silo/probes.go:70`: the key of the probe map. The test
  `TestEveryCapabilityOfTheYamlHasAGoProbe` fails until the key matches.
- `spur-silo/main.go`: D1, D3 and D4 in one place before the command switch,
  the usage text of `--no-gpu`, the three warnings of D3
- `spur-silo/kube.go`: `instinctNodes` becomes `gpuNodes`, `hasInstinct`
  becomes the three-way classifier of D3. Add `kube_test.go` with a table
  test of the classifier: `mi300x`, `mi250x`, `rx9070xt`, `amdgpu-0x1234`,
  `radeon-rx-7900-xtx`, an empty string and a `Gres=` line with no `gpu:`
  entry. It is a pure function, so the test needs no cluster.
- `tests/install-record.sh`, `tests/optional-package-cycle.sh`: the profile
  file names (these scripts go away in C3, but C1 must not leave them broken)
- Comments that name a profile: `tests/smoke.sh`, `tests/smoke-ui.sh`,
  `footprint/footprint.sh:7`

**C2 `feat`: Add the CPU demo profile and run the detector on CPU**

- New `profiles/demo-cpu.yaml` (D5, D6, D7)
- `default-cpu.yaml`: the `aim-engine` values block of D6
- `default.yaml`: `acceleratorDetector.enable: true`, `cpu.enable: false`
  (already there, check it)
- `demo.yaml`: the `aim-engine` entry restated as D7 says
- `profiles_test.go` (D11)

**C3 `refactor`: Rename the spur-silo plugin to spur-inference**

- `git mv byok/spur-silo byok/spur-inference`
- `go.mod`: the module path. The plugin is one `main` package, so no import
  names it.
- `Makefile`: the binary name, the `build` and `clean` targets, the header
  comment
- `.gitignore`: the binary name
- `record.go:15`: `recordNamespace = "inference-system"`
- `kube.go:96`: the temporary kubeconfig name
- `main.go`: the usage text (`spur inference ...`), the `version` output, the
  package comment
- `spur-inference/README.md`
- Delete `byok/spur/spur-silo`, the now empty `byok/spur/` and
  `byok/bootstrap.sh` (D9)
- Port the three tests (D12, section 5), and change
  `.github/workflows/helm-chart-checks.yaml`: the step at line 54 runs
  `tests/validate-negative.sh`, which goes away. Make the step run
  `go test ./...` in `byok/spur-inference` instead. That step then needs a
  Go setup action in the workflow.
- `probes.go:16` and `probes_test.go:10`: correct the comments, see section 5

**C4 `feat`: Confirm before an uninstall and remove every profile by default**

- `main.go`: D13. Split `cmdUninstall` into a planning part that returns what
  goes, what stays and which namespaces the purge deletes, and an executing
  part. The planning part is what the Go test of section 5 exercises.
- The `--yes` flag in `parseArgs` and in the usage text
- The `uninstall` line of the usage text: the name is optional

**C5 `docs`: Update the documents for the inference plugin**

- Every file in section 6
- Rewrite and rename the two ADR files (D10)

## 4. Files that hold an old name

Run this in `byok/` and work through the list. The list below is from
2026-09-17, so check it again.

```
grep -rlnE "spur-silo|spur silo|silo-system|SPUR_SILO|inference-demo|inference-gpu" \
  --exclude-dir=assets --exclude-dir=.git .
```

Do not grep for the bare word `silo`: it matches `silogen` in the module path,
in the image `ghcr.io/silogen/aim-dummy` of `tests/aimservice-dummy.yaml` and
in the label `airm.silogen.ai/workload-id` of `tests/smoke-ui.sh`. Those stay.

Do not change `assets/`. The `Makefile` fills it from `byok/` with
`make assets`.

Code and data: `bootstrap.sh` (deleted), `capabilities.yaml`,
`profiles/*.yaml`, `packages/*/package.yaml`, `packages/aiwb-demo-secrets/*`,
`footprint/footprint.sh`, `tests/*.sh`, `spur-silo/*.go`,
`spur-silo/Makefile`, `spur-silo/.gitignore`, `spur-silo/go.mod`,
`spur/spur-silo` (deleted), `../.github/workflows/helm-chart-checks.yaml`.

## 5. The tests that call bootstrap.sh

`bootstrap.sh` is called by three test scripts: `tests/install-record.sh`,
`tests/optional-package-cycle.sh` and `tests/validate-negative.sh`.
`tests/smoke.sh` names it in a comment only. The GitHub workflow
`helm-chart-checks.yaml` runs `validate-negative.sh` on every pull request.
D9 deletes `bootstrap.sh`.

Two of the three scripts need no cluster. They get that by putting stub
`helm` and `kubectl` scripts on `PATH`. The binary uses the Helm Go library
and client-go, so a stub on `PATH` never runs, and these two tests cannot be
ported as shell scripts that call the binary. They become Go tests. The third
script needs a real cluster and stays a shell script that calls the binary.

**`tests/install-record.sh` becomes `record_test.go`.** The five cases:

1. Both profiles recorded: the shared base stays.
2. Only the child recorded: the base goes too, in reverse install order.
3. Nothing recorded: the profile file gives the package list.
4. A package that is not installed is skipped, not an error.
5. An installed package outside the record still guards its capability.

Cases 1 to 4 test the planning part of the uninstall that C4 splits out. Give
it the record, the profile and a function `installed(pkg) bool`, and assert
the ordered list of what goes and the set of what stays. Case 5 tests
`refuseWhenNeeded`; it asks the cluster which packages are installed, so give
it the same function and a fake that says yes for the guard package.

**`tests/validate-negative.sh` becomes `validate_test.go`.** The cases:

- validation stops on a missing capability, and the message names the
  capability and a provider package
- `extends` of a missing base
- an `extends` chain of two levels
- a required var without a value
- an undeclared variable in the text
- `--var` for a name that the profile does not declare
- a good profile with `extends`, vars and notes validates

The script writes temporary profile files for these. The binary reads
profiles from its embedded `assets/`. Give `readProfile` (`assets.go`) a
package-level `fs.FS` variable that defaults to the embedded files, and set it
to a `fstest.MapFS` in the test. Give `validateProfile` the probe as a
function `probe(capability) bool` instead of a `*cluster`, and pass a function
that always says no.

**`tests/optional-package-cycle.sh` keeps its shape and calls the binary.**
It needs a cluster. The bash form takes a path to a profile file and the
script writes a temporary profile with `seaweedfs` added. The binary takes a
profile name and reads the profile from inside itself, so a temporary profile
is not possible. Test the cycle through `demo-cpu`, and take the comment
marks off `seaweedfs-operator` and `seaweedfs` in `demo.yaml` and
`demo-cpu.yaml` only if the demo needs S3; else add a fifth profile only for
this test. Decide this when you read the test. The map of commands:

| bash | binary |
|---|---|
| `bootstrap.sh install --profile <file>` | `spur-inference install <name>` |
| `bootstrap.sh remove --profile <file> --purge` | `spur-inference uninstall <name> --yes` |
| `bootstrap.sh remove --profile <file>` | `spur-inference uninstall <name> --yes --keep-data` |

`--purge` and `--keep-data` are opposites: bash purges when asked, the binary
keeps when asked. The default of the binary is the purge behaviour. Every
uninstall in a script needs `--yes` (D13).

Do this work in commit C3, together with the deletion of `bootstrap.sh` and
the workflow change. A commit that deletes a script and leaves broken tests or
a red workflow is not revertible in a useful way.

`probes.go:16` and `probes_test.go:10` say that `capabilities.yaml` keeps the
shell form of a probe "for bootstrap.sh". Keep the shell probes, they document
what the Go map does and `optional-package-cycle.sh` runs one of them, but
correct the two comments.

## 6. Documents

Rename the files that hold an old name:
`docs/footprint-inference.md` to `docs/footprint-default-cpu.md`,
`docs/footprint-inference-gpu.md` to `docs/footprint-default.md`,
`docs/footprint-inference-demo.md` to `docs/footprint-demo.md`,
`docs/slide-inference-demo.md` to `docs/slide-demo.md`,
`docs/spur-silo-findings.md` to `docs/spur-inference-findings.md`.

Update the text of: `README.md` (also delete the bash row of the build table
at line 166), `CONTEXT.md`, `docs/spur-cli-plugins.md` (also the lookup names
in the flowchart at line 85), `docs/spur-node-setup.md`,
`docs/test-plan-gpu.md`, `docs/test-plan-kaytoo.md`, `docs/future-work.md`,
and `docs/configuration-reference.md` in the repository root. In that last
file, delete the whole section `byok/spur/spur-silo (the bash build)` (lines
98 to 117, D9), rename the Go section, and add `--yes` and the new meaning of
`--no-gpu` and of a blank name to the flag table.

The test plans and the findings hold command lines and results of tests that
ran with the old names. Change the commands, keep the results. Do not rewrite
history to say that a test used a name that did not exist then. Where a result
names a profile, add the new name in brackets.

Write every document in ASD-STE100 Simplified Technical English. Do not use an
em dash.

## 7. Verification

Without a cluster:

```
cd byok/spur-inference
make assets build test        # test includes profiles_test, record_test, validate_test
./spur-inference list         # four profiles: default, default-cpu, demo, demo-cpu
./spur-inference version
echo | ./spur-inference uninstall --kubeconfig /dev/null   # refuses: stdin is no terminal, --yes absent
```

With a cluster (both `validate` lines connect first):

```
./spur-inference validate                            # validates default
./spur-inference validate demo --no-gpu --var domain=example.com   # validates demo-cpu
./spur-inference install default-cpu --no-gpu        # refused: name already ends with -cpu
```

Then check that no file outside `assets/` matches the grep of section 4.

An install test needs a cluster. `docs/test-plan-kaytoo.md` gives the steps
for a Kaytoo VM, and `docs/test-plan-gpu.md` for a GPU node. Add to the
Kaytoo run:

- `spur inference install` on the VM prints the D3 warning that the cluster
  has no GPU at all, then `spur inference uninstall --yes`.
- On a node with a Radeon card, when one is available: `spur show node`
  shows a `gpu:` type that is not `mi` plus digits, and both
  `spur inference validate` and `spur inference validate --no-gpu` print the
  D3 warning that names the node and the type. Write the result in
  `docs/spur-inference-findings.md`. When no such node is available, the
  table test of `kube_test.go` is the only check, and the findings say so.
- `spur inference install demo-cpu --var domain=...`, then check the CPU
  detector: the DaemonSet whose name ends with `-accelerator-detector-cpu` in
  `aim-system` is ready and the node holds a label
  `feature.node.kubernetes.io/aim-accelerator.EPYC_*`. If it does not, see
  the fallback in D6.
- `spur inference uninstall` with no name and no `--yes` shows the plan and
  asks; answer `n` and check that nothing went away. Then answer `y`, and
  check that `status` reports no profile.
