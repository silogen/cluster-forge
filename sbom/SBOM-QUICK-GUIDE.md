# SBOM Component Management

Scripts to manage component metadata for automated Software Bill of Materials (SBOM) generation.

## Quick Start

1. **Add new component**: Update `values.yaml` → run `./generate-compare-components.sh` → manually add sourceUrl and projectUrl to `components.yaml` → run `./update_licenses.sh`
2. **Remove component**: Remove from `values.yaml` → run `./generate-compare-components.sh`

## Scripts

**`generate-compare-components.sh`** - Syncs `components.yaml` with `root/values.yaml`
- Run after modifying apps in `root/values.yaml`
- Preserves existing metadata

**`update_licenses.sh`** - Auto-populates license info from GitHub
- Run after updating URLs or to refresh licenses
- Only works with GitHub project URLs

## Required Fields in components.yaml

- **sourceUrl**: Where to download the chart/manifest
- **projectUrl**: Main project repository (use GitHub for auto-license detection)
- **license/licenseUrl**: Auto-populated from GitHub by `update_licenses.sh`

## Notes
- Scripts are safe to run multiple times
- Verify auto-populated data before creating PRs
