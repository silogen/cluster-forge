# GitHub Actions Workflows

This directory defines CI/CD for cluster-forge. Workflow file names follow the same convention as [cluster-bloom](https://github.com/silogen/cluster-bloom/tree/main/.github/workflows).

## Naming convention

| Pattern | Example | When to use |
|---------|---------|-------------|
| `pull-request-*.yml` | `pull-request-helm-checks.yml` | Validation that runs on pull requests |
| `integration-tests.yml` | — | Long-running or integration test suites (not used in this repo) |
| `release.yml` | `release.yml` | Release builds, packaging, and publishing |

The `name:` field in each workflow uses the same vocabulary (for example **Pull Request Helm Checks**, **Release**) so both repositories look consistent in the GitHub Actions UI.

## Workflow map

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [pull-request-helm-checks.yml](./pull-request-helm-checks.yml) | Pull requests | Helm lint/template for the root chart and Kyverno policy charts; Kyverno policy test coverage validation |
| [pull-request-component-validation.yml](./pull-request-component-validation.yml) | Pull requests (path-filtered), manual | SBOM/component sync when `sbom/` or related values change |
| [release.yml](./release.yml) | Manual | Calculates version, creates a GitHub Release, packages artifacts, generates SBOM, and uploads to the release |

## Pull request validation

Every PR to `main` runs **Pull Request Helm Checks** (root chart + Kyverno policies).

When a PR touches `sbom/components.yaml`, `root/values.yaml`, or `sbom/*.sh`, **Pull Request Component Validation** also runs via `sbom/validate-sync.sh`.

Neither PR workflow creates or modifies GitHub Releases.

## Release process

Releases are created through **Actions → Release → Run workflow**:

1. **Calculate version** — Uses conventional commits via `ietf-tools/semver-action`, or accepts a manual `version_override`.
2. **Validate bootstrap.sh** — Warns if `LATEST_RELEASE` in `scripts/bootstrap.sh` does not match the release base version.
3. **Create GitHub Release** — Creates a prerelease with the packaged tarball (`release-enterprise-ai-<version>.tar.gz`).
4. **Generate SBOM** — Runs `sbom/generate-sbom.sh` and uploads the SBOM markdown to the release.

To target a specific tag, use `version_override` or create the release in GitHub first and align the workflow input with that tag.

## Adding new checks

- **PR-only validation** → add to an existing `pull-request-*.yml` workflow or create a new one following that naming pattern.
- **Release packaging or SBOM generation** → extend `release.yml`.
- **Path-filtered checks** → follow the pattern in `pull-request-component-validation.yml`.

Do not combine PR validation and release publishing in one workflow.
