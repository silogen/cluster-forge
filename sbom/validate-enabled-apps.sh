#!/bin/bash

set -euo pipefail

# validate-enabled-apps.sh - Validate enabledApps consistency across all cluster sizes
# Checks that all apps in enabledApps from all cluster configurations have corresponding definitions in apps section

BASE_VALUES_FILE="../root/values.yaml"
SMALL_VALUES_FILE="../root/values_small.yaml"
MEDIUM_VALUES_FILE="../root/values_medium.yaml"
LARGE_VALUES_FILE="../root/values_large.yaml"

echo "📋 Validating enabledApps have app definitions across all cluster sizes..."

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
    echo "ℹ️  No enabled apps found in enabledApps list"
    exit 0
fi

# Filter out apps that end with -config (same logic as generate script)
enabled_apps_filtered=$(echo "$enabled_apps" | grep -v -- '-config$' || echo "")

if [[ -z "$enabled_apps_filtered" ]]; then
    echo "ℹ️  No non-config apps found in enabledApps list"
    exit 0
fi

# Function to collect app definitions from a values file
collect_app_definitions() {
    local values_file="$1"
    if [[ -f "$values_file" ]]; then
        yq eval '.apps | keys | .[]' "$values_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Collect app definitions from all cluster size configurations
echo "🔍 Collecting app definitions from all cluster configurations..."
all_defined_apps=""

# Collect from base values.yaml
base_defined_apps=$(collect_app_definitions "$BASE_VALUES_FILE")
if [[ -n "$base_defined_apps" ]]; then
    echo "  📄 Found app definitions in values.yaml: $(echo "$base_defined_apps" | wc -l) apps"
    all_defined_apps="$all_defined_apps$base_defined_apps"$'\n'
fi

# Collect from cluster size values
for size_file in "$SMALL_VALUES_FILE" "$MEDIUM_VALUES_FILE" "$LARGE_VALUES_FILE"; do
    if [[ -f "$size_file" ]]; then
        size_defined_apps=$(collect_app_definitions "$size_file")
        if [[ -n "$size_defined_apps" ]]; then
            size_name=$(basename "$size_file")
            echo "  📄 Found app definitions in $size_name: $(echo "$size_defined_apps" | wc -l) apps"
            all_defined_apps="$all_defined_apps$size_defined_apps"$'\n'
        fi
    fi
done

# Get unique defined apps (remove duplicates and empty lines)
defined_apps=$(echo "$all_defined_apps" | sort -u | grep -v '^$' || echo "")

if [[ -z "$defined_apps" ]]; then
    echo "❌ Error: No app definitions found in any cluster configuration files"
    exit 1
fi

missing_apps=()

# Check each enabled app has a definition
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    
    if ! echo "$defined_apps" | grep -q "^$app$"; then
        missing_apps+=("$app")
        echo "❌ Enabled app '$app' has no definition in apps section"
    else
        echo "✅ App '$app' is properly defined"
    fi
done <<< "$enabled_apps_filtered"

if [ ${#missing_apps[@]} -ne 0 ]; then
    echo ""
    echo "❌ VALIDATION FAILED!"
    echo "The following apps are enabled but have no app definitions:"
    printf '  - %s\n' "${missing_apps[@]}"
    echo ""
    echo "Please add app definitions for these components in the apps section of values.yaml"
    echo ""
    echo "📝 Required action:"
    echo "   Add definitions in the 'apps:' section for each missing app with required fields:"
    echo "   - path: (path to helm chart or manifest)"
    echo "   - namespace: (target namespace)"
    echo "   - Other app-specific configuration as needed"
    exit 1
else
    echo "✅ All enabled apps have corresponding definitions in the apps section"
fi