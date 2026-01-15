#!/bin/bash

set -euo pipefail

# validate-metadata.sh - Validate component metadata completeness
# Checks that all components have required metadata fields populated

COMPONENTS_FILE="./components.yaml"

echo "📝 Validating required metadata fields are populated..."

# Check if components.yaml exists
if [[ ! -f "$COMPONENTS_FILE" ]]; then
    echo "❌ Error: $COMPONENTS_FILE not found"
    echo "Please run ./generate-compare-components.sh to create components.yaml"
    exit 1
fi

# Get all component names
component_names=$(yq eval '.components | keys | .[]' "$COMPONENTS_FILE" 2>/dev/null || echo "")

if [[ -z "$component_names" ]]; then
    echo "ℹ️  No components found in components.yaml"
    exit 0
fi

missing_fields=false
missing_components=()

# Check each component for missing fields
while IFS= read -r component; do
    [[ -z "$component" ]] && continue
    
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    license=$(yq eval ".components.\"$component\".license // \"\"" "$COMPONENTS_FILE")
    license_url=$(yq eval ".components.\"$component\".licenseUrl // \"\"" "$COMPONENTS_FILE")
    
    component_missing=false
    
    if [[ -z "$source_url" ]]; then
        echo "❌ Missing sourceUrl for component: $component"
        missing_fields=true
        component_missing=true
    fi
    
    if [[ -z "$project_url" ]]; then
        echo "❌ Missing projectUrl for component: $component"
        missing_fields=true
        component_missing=true
    fi
    
    if [[ -z "$license" ]]; then
        echo "❌ Missing license for component: $component"
        missing_fields=true
        component_missing=true
    fi
    
    if [[ -z "$license_url" ]]; then
        echo "❌ Missing licenseUrl for component: $component"
        missing_fields=true
        component_missing=true
    fi
    
    if [[ "$component_missing" == true ]]; then
        missing_components+=("$component")
    else
        echo "✅ Component $component has all required fields"
    fi
done <<< "$component_names"

if [[ "$missing_fields" == true ]]; then
    echo ""
    echo "❌ METADATA VALIDATION FAILED!"
    echo "The following components are missing required fields:"
    for comp in "${missing_components[@]}"; do
        echo "  - $comp"
    done
    echo ""
    echo "Please ensure all components have 'sourceUrl', 'projectUrl', 'license', and 'licenseUrl' populated in components.yaml"
    echo ""
    echo "📝 Manual steps required:"
    echo "   1. Fill in 'sourceUrl' and 'projectUrl' manually for missing components"
    echo "   2. Run ./update_licenses.sh to auto-populate license fields from GitHub"
    echo ""
    echo "💡 Note: 'sourceUrl' and 'projectUrl' must be provided manually as they require"
    echo "   human knowledge about where to find charts/manifests and project repositories."
    exit 1
else
    echo "✅ All components have required metadata fields populated"
fi