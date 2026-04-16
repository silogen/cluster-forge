#!/bin/bash

set -euo pipefail

# validate-components-sync.sh - Validate components.yaml sync with enabledApps across all cluster sizes
# Checks that components.yaml reflects current enabledApps and path consistency

BASE_VALUES_FILE="../root/values.yaml"
SMALL_VALUES_FILE="../root/values_small.yaml"
MEDIUM_VALUES_FILE="../root/values_medium.yaml"
LARGE_VALUES_FILE="../root/values_large.yaml"
COMPONENTS_FILE="./components.yaml"

echo "🔄 Validating components.yaml reflects enabledApps..."

# Check if components.yaml exists
if [[ ! -f "$COMPONENTS_FILE" ]]; then
    echo "❌ Error: $COMPONENTS_FILE not found"
    echo "Please run ./generate-compare-components.sh to create components.yaml"
    exit 1
fi

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
all_enabled_apps=""

# Collect from base values.yaml (if enabledApps exists)
base_apps=$(collect_enabled_apps "$BASE_VALUES_FILE")
if [[ -n "$base_apps" ]]; then
    all_enabled_apps="$all_enabled_apps$base_apps"$'\n'
fi

# Collect from cluster size values
for size_file in "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
    if [[ -f "$size_file" ]]; then
        size_apps=$(collect_enabled_apps "$size_file")
        if [[ -n "$size_apps" ]]; then
            all_enabled_apps="$all_enabled_apps$size_apps"$'\n'
        fi
    fi
done

# Get unique enabled apps (remove duplicates and empty lines)
enabled_apps=$(echo "$all_enabled_apps" | sort -u | grep -v '^$' || echo "")
enabled_apps_filtered=$(echo "$enabled_apps" | grep -v -- '-config$' || echo "")

# Get components in components.yaml
existing_components=$(yq eval '.components | keys | .[]' "$COMPONENTS_FILE" 2>/dev/null || echo "")

# Check for missing components (in enabledApps but not in components.yaml)
missing_components=()
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if ! echo "$existing_components" | grep -q "^$app$"; then
        missing_components+=("$app")
        echo "❌ Component missing: '$app' is enabled but not in components.yaml"
    fi
done <<< "$enabled_apps_filtered"

# Check for extra components (in components.yaml but not in enabledApps)
extra_components=()
while IFS= read -r component; do
    [[ -z "$component" ]] && continue
    if ! echo "$enabled_apps_filtered" | grep -q "^$component$"; then
        extra_components+=("$component")
        echo "❌ Component extra: '$component' is in components.yaml but not enabled"
    fi
done <<< "$existing_components"

if [ ${#missing_components[@]} -ne 0 ] || [ ${#extra_components[@]} -ne 0 ]; then
    echo ""
    echo "❌ COMPONENTS SYNC FAILED!"
    if [ ${#missing_components[@]} -ne 0 ]; then
        echo "Missing components (run ./generate-compare-components.sh):"
        printf '  - %s\n' "${missing_components[@]}"
    fi
    if [ ${#extra_components[@]} -ne 0 ]; then
        echo "Extra components (remove from enabledApps or regenerate):"
        printf '  - %s\n' "${extra_components[@]}"
    fi
    echo ""
    echo "📝 Required action: Run ./generate-compare-components.sh to sync components.yaml"
    exit 1
fi

# Check path consistency between cluster configuration files and components.yaml
echo "⚙️ Checking path/valuesFile consistency..."
path_mismatches=()

while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    
    # Find the app definition in any of the cluster configuration files
    values_path=""
    for config_file in "$BASE_VALUES_FILE" "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
        if [[ -f "$config_file" ]]; then
            app_path=$(yq eval ".apps.\"$app\".path // \"null\"" "$config_file" 2>/dev/null || echo "null")
            if [[ "$app_path" != "null" ]]; then
                values_path="$app_path"
                break
            fi
        fi
    done
    
    component_path=$(yq eval ".components.\"$app\".path" "$COMPONENTS_FILE" 2>/dev/null || echo "null")
    
    if [[ "$values_path" != "$component_path" ]]; then
        path_mismatches+=("$app: cluster-configs='$values_path' vs components.yaml='$component_path'")
        echo "❌ Path mismatch for '$app': cluster-configs='$values_path' vs components.yaml='$component_path'"
    fi
    
    # Check valuesFile/valuesFiles consistency
    values_file_values="null"
    values_files_values="null"
    config_file_source=""
    for config_file in "$BASE_VALUES_FILE" "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
        if [[ -f "$config_file" ]]; then
            app_path_check=$(yq eval ".apps.\"$app\".path // \"null\"" "$config_file" 2>/dev/null || echo "null")
            if [[ "$app_path_check" != "null" ]]; then
                values_file_values=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$config_file" 2>/dev/null || echo "null")
                values_files_values=$(yq eval ".apps.\"$app\".valuesFiles // \"null\"" "$config_file" 2>/dev/null || echo "null")
                config_file_source="$config_file"
                break
            fi
        fi
    done

    values_file_components=$(yq eval ".components.\"$app\".valuesFile // \"null\"" "$COMPONENTS_FILE" 2>/dev/null || echo "null")
    values_files_components=$(yq eval ".components.\"$app\".valuesFiles // \"null\"" "$COMPONENTS_FILE" 2>/dev/null || echo "null")

    # Compare - prefer valuesFiles if present, otherwise fall back to valuesFile
    if [[ "$values_files_values" != "null" ]] || [[ "$values_files_components" != "null" ]]; then
        # At least one side uses valuesFiles (array) - compare as JSON to normalize formatting
        if [[ "$values_files_values" != "null" ]] && [[ "$values_files_components" != "null" ]]; then
            # Both have valuesFiles - convert to JSON for comparison
            values_files_values_json=$(yq eval ".apps.\"$app\".valuesFiles" "$config_file_source" -o=json 2>/dev/null || echo "null")
            values_files_components_json=$(yq eval ".components.\"$app\".valuesFiles" "$COMPONENTS_FILE" -o=json 2>/dev/null || echo "null")

            if [[ "$values_files_values_json" != "$values_files_components_json" ]]; then
                path_mismatches+=("$app valuesFiles: cluster-configs='$values_files_values_json' vs components.yaml='$values_files_components_json'")
                echo "❌ ValuesFiles mismatch for '$app': cluster-configs='$values_files_values_json' vs components.yaml='$values_files_components_json'"
            fi
        else
            # Only one side has valuesFiles - they don't match
            path_mismatches+=("$app valuesFiles: cluster-configs='$values_files_values' vs components.yaml='$values_files_components'")
            echo "❌ ValuesFiles mismatch for '$app': cluster-configs='$values_files_values' vs components.yaml='$values_files_components'"
        fi
    elif [[ "$values_file_values" != "$values_file_components" ]]; then
        # Both sides use valuesFile (singular)
        path_mismatches+=("$app valuesFile: cluster-configs='$values_file_values' vs components.yaml='$values_file_components'")
        echo "❌ ValuesFile mismatch for '$app': cluster-configs='$values_file_values' vs components.yaml='$values_file_components'"
    fi
done <<< "$enabled_apps_filtered"

if [ ${#path_mismatches[@]} -ne 0 ]; then
    echo ""
    echo "❌ PATH/CONFIG SYNC FAILED!"
    echo "Path/configuration mismatches found:"
    printf '  - %s\n' "${path_mismatches[@]}"
    echo ""
    echo "📝 Required action: Run ./generate-compare-components.sh to sync path/valuesFile information"
    exit 1
fi

echo "✅ Components.yaml is properly synced with enabledApps"