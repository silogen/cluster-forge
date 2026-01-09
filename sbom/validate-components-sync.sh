#!/bin/bash

set -euo pipefail

# validate-components-sync.sh - Validate components.yaml sync with enabledApps
# Checks that components.yaml reflects current enabledApps and path consistency

VALUES_FILE="../root/values.yaml"
COMPONENTS_FILE="./components.yaml"

echo "🔄 Validating components.yaml reflects enabledApps..."

# Check if components.yaml exists
if [[ ! -f "$COMPONENTS_FILE" ]]; then
    echo "❌ Error: $COMPONENTS_FILE not found"
    echo "Please run ./generate-compare-components.sh to create components.yaml"
    exit 1
fi

# Check if values.yaml exists
if [[ ! -f "$VALUES_FILE" ]]; then
    echo "❌ Error: $VALUES_FILE not found"
    exit 1
fi

# Get enabled apps (filtered, same as generation script)
enabled_apps=$(yq eval '.enabledApps[]' "$VALUES_FILE" 2>/dev/null || echo "")
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

# Check path consistency between values.yaml and components.yaml
echo "⚙️ Checking path/valuesFile consistency..."
path_mismatches=()

while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    
    # Get paths from both files
    values_path=$(yq eval ".apps.\"$app\".path" "$VALUES_FILE" 2>/dev/null || echo "null")
    component_path=$(yq eval ".components.\"$app\".path" "$COMPONENTS_FILE" 2>/dev/null || echo "null")
    
    if [[ "$values_path" != "$component_path" ]]; then
        path_mismatches+=("$app: values.yaml='$values_path' vs components.yaml='$component_path'")
        echo "❌ Path mismatch for '$app': values.yaml='$values_path' vs components.yaml='$component_path'"
    fi
    
    # Check valuesFile consistency
    values_file_values=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$VALUES_FILE" 2>/dev/null || echo "null")
    values_file_components=$(yq eval ".components.\"$app\".valuesFile // \"null\"" "$COMPONENTS_FILE" 2>/dev/null || echo "null")
    
    if [[ "$values_file_values" != "$values_file_components" ]]; then
        path_mismatches+=("$app valuesFile: values.yaml='$values_file_values' vs components.yaml='$values_file_components'")
        echo "❌ ValuesFile mismatch for '$app': values.yaml='$values_file_values' vs components.yaml='$values_file_components'"
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