# GitHub Actions Workflows

This directory contains CI/CD workflows for cluster-forge.

## Workflow files

| Workflow | Trigger | Purpose |
|---|---|---|
| `helm-chart-checks.yaml` | `pull_request` | Validates Helm charts and Kyverno policy test coverage. |
| `pr-component-validation.yaml` | `pull_request` (path-filtered), `workflow_dispatch` | Validates SBOM/component sync when key files change. |
| `release-pipeline.yaml` | `workflow_dispatch` | Calculates release version, creates prerelease artifact, and publishes SBOM. |

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

- Manual workflow with optional input: `version_override`.
- Job `release`:
  - Checks out full history.
  - Computes next semantic version (`ietf-tools/semver-action`) unless overridden.
  - Packages `root/`, `scripts/`, and `sources/` into `release-enterprise-ai-<version>.tar.gz`.
  - Creates a GitHub prerelease with generated notes.
- Job `sbom` (depends on `release`):
  - Generates SBOM via `sbom/generate-sbom.sh`.
  - Renames output to `sbom-<version>-<short-sha>.md`.
  - Uploads SBOM asset to the GitHub release with `--clobber`.

## Operating notes

- PR workflows perform validation only and do not publish releases.
- Use **Actions -> Release Pipeline -> Run workflow** to cut a release.
- Set `version_override` when you need a specific tag.
