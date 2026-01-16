# SBOM Component Management

Scripts to manage component metadata for automated Software Bill of Materials (SBOM) generation.

## Essential Workflow

When `root/values.yaml` has a new tool, you need to run these commands manually:

```bash
# 1. Generate/sync components from enabledApps
./generate-compare-components.sh

# 2. Manually fill out sourceUrl and projectUrl in components.yaml
# (requires human knowledge about chart/manifest locations)

# 3. Auto-populate license information
./update_licenses.sh

# 4. Validate everything is ready
./validate-sync.sh
```

## Quick Start

### Adding a New Component
1. **Update values.yaml**: Add to `enabledApps` list AND add app definition in `apps` section  
2. **Run workflow**: Execute the 4 commands above
3. **Commit changes**: All files should be ready for PR

### Removing a Component
1. **Remove from enabledApps**: Remove from `enabledApps` list in `root/values.yaml`
2. **Regenerate**: Run `./generate-compare-components.sh` (automatically removes from components.yaml)
3. **Validate**: Run `./validate-sync.sh` to confirm removal

## Scripts

### Generation Scripts
**`generate-compare-components.sh`** - Syncs `components.yaml` with enabled apps from `root/values.yaml`
- Processes only apps listed in `enabledApps` (excludes `-config` apps)
- Includes pre-validation to catch configuration issues early
- Preserves existing metadata (sourceUrl, projectUrl, license fields)
- Creates timestamped backups when needed

**`update_licenses.sh`** - Auto-populates license info from GitHub
- Run after updating URLs or to refresh licenses
- Only works with GitHub project URLs

### Validation Scripts (New Modular System)
**`validate-sync.sh`** - 🛡️ **Main validation command** - Comprehensive SBOM sync validator
- Orchestrates all validation checks
- Use this for complete validation before commits

**Individual Validators** (for targeted debugging):
- **`validate-enabled-apps.sh`** - Checks enabledApps have corresponding app definitions
- **`validate-components-sync.sh`** - Verifies components.yaml reflects current enabledApps
- **`validate-metadata.sh`** - Ensures all required metadata fields are populated

## Validation Workflow

The new modular validation system ensures data consistency:

```
1. EnabledApps Consistency Check
   ├── Validates all enabledApps have app definitions
   └── Filters out -config apps appropriately

2. Components Sync Check  
   ├── Verifies components.yaml matches enabledApps
   ├── Checks for missing/extra components
   └── Validates path/valuesFile consistency

3. Metadata Completeness Check
   ├── Ensures sourceUrl and projectUrl are populated
   └── Verifies license and licenseUrl fields exist
```

## Required Fields in components.yaml

- **sourceUrl**: Where to download the chart/manifest (⚠️ Manual entry required)
- **projectUrl**: Main project repository (⚠️ Manual entry required - use GitHub for auto-license detection)
- **license/licenseUrl**: Auto-populated from GitHub by `update_licenses.sh`
- **path**: Auto-synced from values.yaml by generation script
- **valuesFile**: Auto-synced from values.yaml when present

## CI/CD Integration

The GitHub workflow `.github/workflows/pr-component-validation.yaml` now includes:
1. **EnabledApps validation** (prevents mismatched configurations)
2. **Component generation** (ensures SBOM reflects enabled apps)
3. **Metadata validation** (ensures completeness)
4. **Sync verification** (catches uncommitted changes)

## Important Notes

- **EnabledApps is the source of truth**: Components are generated only for apps in the `enabledApps` list
- **Manual metadata required**: `sourceUrl` and `projectUrl` must be added manually (requires human knowledge)
- **Scripts are idempotent**: Safe to run multiple times
- **Validation before commit**: Always run `./validate-sync.sh` before creating PRs
- **Backup safety**: Existing data is preserved through timestamped backups

## Troubleshooting

**Error: "Enabled app has no definition"**
→ Add the app definition to the `apps` section in `root/values.yaml`

**Error: "Component missing/extra"** 
→ Run `./generate-compare-components.sh` to sync components.yaml

**Error: "Missing sourceUrl/projectUrl"**
→ Manually add the missing URLs to components.yaml

**Error: "Path/configuration mismatch"**
→ Run `./generate-compare-components.sh` to sync path information
