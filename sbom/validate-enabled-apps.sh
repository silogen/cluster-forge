#!/bin/bash

set -euo pipefail

# validate-enabled-apps.sh - Validate enabledApps consistency
# Checks that all apps in enabledApps have corresponding definitions in apps section

VALUES_FILE="../root/values.yaml"

echo "📋 Validating enabledApps have app definitions..."

# Check if values.yaml exists
if [[ ! -f "$VALUES_FILE" ]]; then
    echo "❌ Error: $VALUES_FILE not found"
    exit 1
fi

# Get all enabled apps
enabled_apps=$(yq eval '.enabledApps[]' "$VALUES_FILE" 2>/dev/null || echo "")

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

# Get all defined apps in apps section
defined_apps=$(yq eval '.apps | keys | .[]' "$VALUES_FILE" 2>/dev/null || echo "")

if [[ -z "$defined_apps" ]]; then
    echo "❌ Error: No app definitions found in apps section"
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