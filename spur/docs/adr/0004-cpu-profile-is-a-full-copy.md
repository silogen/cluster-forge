---
status: accepted
date: 2026-09-17
---

# A `-cpu` profile is a full copy of its GPU twin, held by a test

`default-cpu.yaml` is a copy of `default.yaml`, and `demo-cpu.yaml` is a copy
of `demo.yaml` with `extends: default-cpu`. A `-cpu` profile is not an
`extends` child of its GPU twin, and there is no subtraction mechanism in the
profile format.

The two files differ in exactly three things:

1. The packages `amd-gpu-operator` and `amd-gpu-operator-config` are absent
   from the `-cpu` profile.
2. `aim-catalog` takes `hardwareFamilies: [epyc]`, not `[instinct]`.
3. The accelerator detector is off in the `-cpu` profile. Its result goes
   into a node-feature-discovery file that nothing reads on a cluster without
   the GPU operator.

`profiles_test.go` reads the four files from `spur/profiles` and fails when
the pairs differ in anything else. The same test holds `demo` to the
`aim-engine` values of `default` plus the keys that the aiwb chart makes
unnecessary, because `extends` replaces a package entry as a whole and a
restated entry can drift too.

## Considered options

- `extends` plus a `remove` list in the child profile. Rejected: the AMD GPU
  operator must install before `aim-engine`, because the detector reads the
  labels that node-feature-discovery writes, and `extends` puts a package that
  only the child holds at the end of the list. A subtraction mechanism needs
  about twenty lines of merge code that run on every install, for a difference
  of three items.
- One profile with a `gpu: true|false` switch and conditional packages.
  Rejected: a profile is an ordered package list that an operator can read as
  it is. A condition in the format makes every profile harder to read for a
  case that two files cover.

## Consequences

- A change to a GPU profile needs the same change in its `-cpu` twin. The
  test says so when it is missing, so the drift shows in CI and not at install
  time.
- A new profile pair needs a new entry in the pair list of the test.
- The test reads the source files, so it runs without `just assets`.
