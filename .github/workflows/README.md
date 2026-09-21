# GitHub Actions Workflows

This directory contains CI/CD workflows for cluster-forge.

## Workflow files

| Workflow | Trigger | Purpose |
|---|---|---|
| `helm-chart-checks.yaml` | `pull_request` | Validates Helm charts and Kyverno policy test coverage. |
| `pr-component-validation.yaml` | `pull_request` (path-filtered), `workflow_dispatch` | Validates SBOM/component sync when key files change. |
| `release-pipeline.yaml` | `workflow_dispatch` | Calculates or overrides a release version, creates a GitHub release (not a prerelease), and publishes SBOM. Arbitrary tags do not become Latest unless `mark_as_latest` is set. |

## Workflow details

### `helm-chart-checks.yaml`

- Runs on PR events (`opened`, `synchronize`, `reopened`, `ready_for_review`, `converted_to_draft`).
- Validates `root` chart with all sizing values files (`values`, `values_small`, `values_medium`, `values_large`).
- Lints and templates Kyverno policy charts.
- Enforces Kyverno test coverage (test folder, `kyverno-test.yaml`, resource files, and policy mapping).
- Runs `kyverno test` against generated policy manifests.
- Includes a comprehensive coverage job to ensure all charts under `sources/kyverno-policies` are included in CI.

### `pr-component-validation.yaml`

- Runs on manual dispatch and PRs to `main` when these files change:
  - `sbom/components.yaml`
  - `root/values.yaml`
  - `sbom/*.sh`
- Installs `yq` and executes `sbom/validate-sync.sh`.
- Acts as a gate to keep SBOM/component definitions consistent.

### `release-pipeline.yaml`

- Manual workflow with optional inputs:
  - `version_override` — leave empty to auto-calculate the next semver tag, or set any tag (including a backport) to publish that version from the branch you run on.
  - `mark_as_latest` — boolean, default `false`. GitHub otherwise treats a new non-prerelease as Latest; keep this false so an arbitrary tag does not replace the current Latest release. Set it only when this run should own Latest.
- Job `release`:
  - Checks out full history.
  - Computes next semantic version (`ietf-tools/semver-action`) unless `version_override` is set.
  - Packages `root/`, `scripts/`, and `sources/` into `release-enterprise-ai-<version>.tar.gz`.
  - Creates a GitHub **release** (not `--prerelease`) with generated notes, passing `--latest` or `--latest=false` from `mark_as_latest`.
- Job `sbom` (depends on `release`):
  - Generates SBOM via `sbom/generate-sbom.sh`.
  - Renames output to `sbom-<version>-<short-sha>.md`.
  - Uploads SBOM asset to the GitHub release with `--clobber`.

## Operating notes

- PR workflows perform validation only and do not publish releases.
- Use **Actions -> Release Pipeline -> Run workflow** to cut a release.
- Set `version_override` when you need a specific tag (any line, not only the current Latest).
- Leave `mark_as_latest` unchecked unless this publish should become GitHub Latest.
