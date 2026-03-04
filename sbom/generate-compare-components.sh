#!/bin/bash

set -euo pipefail

# Script to update components.yaml from enabledApps across all cluster sizes
# Collects components from values.yaml, values_small.yaml, values_medium.yaml, values_large.yaml
# Only updates if there are new items or changes to existing ones
# Preserves existing sourceUrl and projectUrl values
# Only includes apps that are in the enabledApps list (excluding -config apps)

BASE_VALUES_FILE="../root/values.yaml"
SMALL_VALUES_FILE="../root/values_small.yaml"
MEDIUM_VALUES_FILE="../root/values_medium.yaml"
LARGE_VALUES_FILE="../root/values_large.yaml"
OUTPUT_FILE="./components.yaml"
TEMP_FILE="./components.yaml.tmp"

echo "⚙️ Generating/Updating components.yaml from enabledApps across all cluster sizes..."

# Self-validation: Check enabledApps consistency before processing (fail-fast)
echo "🔍 Pre-validation: Checking enabledApps consistency..."
if [[ -f "./validate-enabled-apps.sh" ]]; then
    if ! ./validate-enabled-apps.sh; then
        echo ""
        echo "❌ Pre-validation failed! Cannot generate components.yaml with invalid enabledApps."
        echo "Please fix the enabledApps issues above before running generation."
        exit 1
    fi
    echo "✅ Pre-validation passed - proceeding with generation..."
else
    echo "⚠️  Warning: validate-enabled-apps.sh not found, skipping pre-validation"
fi

echo ""
echo "Checking for updates to components.yaml..."

# Function to collect enabled apps from a values file
collect_enabled_apps() {
    local values_file="$1"
    if [[ -f "$values_file" ]]; then
        yq eval '.enabledApps[]' "$values_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Collect enabled apps from all cluster size configurations
echo "🔍 Collecting enabled apps from all cluster configurations..."
all_enabled_apps=""

# Collect from base values.yaml (if enabledApps exists)
base_apps=$(collect_enabled_apps "$BASE_VALUES_FILE")
if [[ -n "$base_apps" ]]; then
    echo "  📄 Found apps in values.yaml: $(echo "$base_apps" | wc -l) apps"
    all_enabled_apps="$all_enabled_apps$base_apps"$'\n'
fi

# Collect from small cluster values
small_apps=$(collect_enabled_apps "$SMALL_VALUES_FILE")
if [[ -n "$small_apps" ]]; then
    echo "  📄 Found apps in values_small.yaml: $(echo "$small_apps" | wc -l) apps"
    all_enabled_apps="$all_enabled_apps$small_apps"$'\n'
fi

# Collect from medium cluster values
medium_apps=$(collect_enabled_apps "$MEDIUM_VALUES_FILE")
if [[ -n "$medium_apps" ]]; then
    echo "  📄 Found apps in values_medium.yaml: $(echo "$medium_apps" | wc -l) apps"
    all_enabled_apps="$all_enabled_apps$medium_apps"$'\n'
fi

# Collect from large cluster values
large_apps=$(collect_enabled_apps "$LARGE_VALUES_FILE")
if [[ -n "$large_apps" ]]; then
    echo "  📄 Found apps in values_large.yaml: $(echo "$large_apps" | wc -l) apps"
    all_enabled_apps="$all_enabled_apps$large_apps"$'\n'
fi

# Get unique enabled apps (remove duplicates and empty lines)
enabled_apps=$(echo "$all_enabled_apps" | sort -u | grep -v '^$' || echo "")

if [[ -z "$enabled_apps" ]]; then
    echo "Warning: No enabled apps found in enabledApps list"
    if [[ -f "$OUTPUT_FILE" ]]; then
        backup_file="./components-old-$(date +%Y%m%d-%H%M%S).yaml"
        echo "Backing up existing $OUTPUT_FILE to $backup_file"
        mv "$OUTPUT_FILE" "$backup_file"
    fi
    exit 0
fi

app_names=$(echo "$enabled_apps" | grep -v -- '-config$' || echo "")

if [[ -z "$app_names" ]]; then
    echo "Warning: No non-config apps found in enabledApps list"
    if [[ -f "$OUTPUT_FILE" ]]; then
        backup_file="./components-old-$(date +%Y%m%d-%H%M%S).yaml"
        echo "Backing up existing $OUTPUT_FILE to $backup_file (only config apps enabled)"
        mv "$OUTPUT_FILE" "$backup_file"
    fi
    exit 0
fi

# Check if components.yaml exists
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "Creating new $OUTPUT_FILE..."
    needs_update=true
else
    echo "Existing $OUTPUT_FILE found. Checking for changes..."
    needs_update=false
    
    # Check each enabled app from values.yaml
    for app in $app_names; do
        # Get current values from apps section (check all cluster files)
        current_path=""
        current_values_file="null"
        
        # Try to find the app definition in any of the cluster configuration files
        for values_file in "$BASE_VALUES_FILE" "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
            if [[ -f "$values_file" ]]; then
                app_path=$(yq eval ".apps.\"$app\".path // \"null\"" "$values_file" 2>/dev/null || echo "null")
                if [[ "$app_path" != "null" ]]; then
                    current_path="$app_path"
                    current_values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$values_file")
                    break
                fi
            fi
        done
        
        # Check if app exists in components.yaml
        existing_app=$(yq eval ".components.\"$app\" // \"null\"" "$OUTPUT_FILE")
        
        if [[ "$existing_app" == "null" ]]; then
            echo "  New app found: $app"
            needs_update=true
            break
        fi
        
        # Check if path changed
        existing_path=$(yq eval ".components.\"$app\".path // \"null\"" "$OUTPUT_FILE")
        if [[ "$existing_path" != "$current_path" ]]; then
            echo "  Path changed for $app: $existing_path -> $current_path"
            needs_update=true
            break
        fi
        
        # Check if valuesFile changed
        existing_values_file=$(yq eval ".components.\"$app\".valuesFile // \"null\"" "$OUTPUT_FILE")
        if [[ "$existing_values_file" != "$current_values_file" ]]; then
            echo "  ValuesFile changed for $app: $existing_values_file -> $current_values_file"
            needs_update=true
            break
        fi
    done
    
    # Check for removed apps (apps in components.yaml that are no longer in enabledApps)
    if [[ "$needs_update" == "false" ]]; then
        existing_components=$(yq eval '.components | keys | .[]' "$OUTPUT_FILE" 2>/dev/null || echo "")
        for existing_component in $existing_components; do
            if ! echo "$app_names" | grep -q "^$existing_component$"; then
                echo "  Removed app found: $existing_component (no longer in enabledApps)"
                needs_update=true
                break
            fi
        done
    fi
fi

if [[ "$needs_update" == "false" ]]; then
    echo "No updates needed. components.yaml is up to date."
    exit 0
fi

echo "Updating $OUTPUT_FILE..."

# Create components.yaml header
cat > "$TEMP_FILE" << 'EOF'
# Generated components metadata for SBOM creation
# This file contains simplified component information for apps across all cluster sizes
# Collected from: values.yaml, values_small.yaml, values_medium.yaml, values_large.yaml
# Apps with "config" suffix are excluded from this SBOM

components:
EOF

# Process each app
for app in $app_names; do
    echo "  $app:" >> "$TEMP_FILE"
    
    # Get path and valuesFile from any cluster configuration file
    path=""
    values_file="null"
    
    # Try to find the app definition in any of the cluster configuration files
    for config_file in "$BASE_VALUES_FILE" "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
        if [[ -f "$config_file" ]]; then
            app_path=$(yq eval ".apps.\"$app\".path // \"null\"" "$config_file" 2>/dev/null || echo "null")
            if [[ "$app_path" != "null" ]]; then
                path="$app_path"
                values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$config_file")
                break
            fi
        fi
    done
    
    echo "    path: $path" >> "$TEMP_FILE"
    if [[ "$values_file" != "null" ]]; then
        echo "    valuesFile: $values_file" >> "$TEMP_FILE"
    fi
    
    # Preserve existing sourceUrl, projectUrl, license, and licenseUrl if they exist, otherwise add empty ones
    if [[ -f "$OUTPUT_FILE" ]]; then
        existing_source_url=$(yq eval ".components.\"$app\".sourceUrl // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        existing_project_url=$(yq eval ".components.\"$app\".projectUrl // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        existing_license=$(yq eval ".components.\"$app\".license // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        existing_license_url=$(yq eval ".components.\"$app\".licenseUrl // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$existing_source_url" ]]; then
            echo "    sourceUrl: $existing_source_url" >> "$TEMP_FILE"
        else
            echo "    sourceUrl:" >> "$TEMP_FILE"
        fi
        
        if [[ -n "$existing_project_url" ]]; then
            echo "    projectUrl: $existing_project_url" >> "$TEMP_FILE"
        else
            echo "    projectUrl:" >> "$TEMP_FILE"
        fi
        
        if [[ -n "$existing_license" ]]; then
            echo "    license: $existing_license" >> "$TEMP_FILE"
        else
            echo "    license:" >> "$TEMP_FILE"
        fi
        
        if [[ -n "$existing_license_url" ]]; then
            echo "    licenseUrl: $existing_license_url" >> "$TEMP_FILE"
        else
            echo "    licenseUrl:" >> "$TEMP_FILE"
        fi
    else
        # New file, add empty fields
        echo "    sourceUrl:" >> "$TEMP_FILE"
        echo "    projectUrl:" >> "$TEMP_FILE"
        echo "    license:" >> "$TEMP_FILE"
        echo "    licenseUrl:" >> "$TEMP_FILE"
    fi
done

# Replace the original file
mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "✅ Updated $OUTPUT_FILE successfully"
echo ""
echo "📊 Summary of components:"
echo "$app_names" | wc -l | xargs echo "Total components:"
echo ""
echo "Components with valuesFile:"
for app in $app_names; do
    # Check all cluster configuration files for valuesFile
    values_file="null"
    for config_file in "$BASE_VALUES_FILE" "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
        if [[ -f "$config_file" ]]; then
            app_path=$(yq eval ".apps.\"$app\".path // \"null\"" "$config_file" 2>/dev/null || echo "null")
            if [[ "$app_path" != "null" ]]; then
                values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$config_file")
                break
            fi
        fi
    done
    if [[ "$values_file" != "null" ]]; then
        echo "  - $app"
    fi
done

echo ""
echo "✅ Components generated/updated successfully!"
echo ""
echo "📝 Next steps:"
echo "  1. Fill in 'sourceUrl' and 'projectUrl' for any components with empty values"
echo "  2. Run ./update_licenses.sh to auto-populate license fields from GitHub"  
echo "  3. Run ./validate-sync.sh to verify everything is ready for commit"
echo ""
echo "💡 Tip: Use individual validation scripts for targeted debugging:"
echo "  - ./validate-enabled-apps.sh     (check app definitions)"
echo "  - ./validate-components-sync.sh  (check sync status)"
echo "  - ./validate-metadata.sh         (check required fields)"