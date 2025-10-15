#!/bin/bash

# Generate Software Bill of Materials (SBOM) from components.yaml
# This script reads components.yaml and creates SBOM.md

set -euo pipefail

COMPONENTS_FILE="components.yaml"
SBOM_FILE="SBOM.md"

# Check if components.yaml exists
if [[ ! -f "$COMPONENTS_FILE" ]]; then
    echo "Error: $COMPONENTS_FILE not found"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed"
    exit 1
fi

# Function to extract version from path
extract_version() {
    local path="$1"
    # Extract version patterns like v1.2.3, 1.2.3, etc.
    # Try different patterns to match versions
    if [[ "$path" =~ /v?([0-9]+\.[0-9]+\.[0-9]+[^/]*) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$path" =~ /(v[0-9]+\.[0-9]+\.[0-9]+[^/]*) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$path" =~ /([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        # If no version pattern found, try to get the last part after /
        echo "$path" | sed 's|.*/||'
    fi
}

# Function to categorize component (helm vs manifest)
categorize_component() {
    local source_url="$1"
    
    # Kubernetes manifests (direct YAML files)
    if [[ "$source_url" == *".yaml"* ]] || [[ "$source_url" == *".yml"* ]]; then
        echo "manifest"
        return
    fi
    
    # GitHub releases with install.yaml are typically manifests
    if [[ "$source_url" == *"github.com"* ]] && [[ "$source_url" == *"releases"* ]] && [[ "$source_url" == *".yaml"* ]]; then
        echo "manifest"
        return
    fi
    
    # Default to helm for most others (OCI, helm repos, etc.)
    echo "helm"
}

# Get all component names using yq
component_names=$(yq eval '.components | keys | .[]' "$COMPONENTS_FILE")

# Start generating SBOM
cat > "$SBOM_FILE" << 'EOF'
# Software Bill of Materials (SBOM) - Complete

## All Components

| No | Name | Version | Project |
|----|------|---------|---------|
EOF

# Generate all components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    
    # Extract version from path
    version=$(extract_version "$path")
    
    # Add to all components table
    echo "| $counter | $component | $version | $project_url |" >> "$SBOM_FILE"
    ((counter++))
done

# Add Helm Charts section
cat >> "$SBOM_FILE" << 'EOF'

## Helm Charts

| No | Name | Version | Project |
|----|------|---------|---------|
EOF

# Generate helm components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    
    # Check if it's a helm component
    category=$(categorize_component "$source_url")
    if [[ "$category" == "helm" ]]; then
        version=$(extract_version "$path")
        echo "| $counter | $component | $version | $project_url |" >> "$SBOM_FILE"
        ((counter++))
    fi
done

# Add Kubernetes Manifests section
cat >> "$SBOM_FILE" << 'EOF'

## Kubernetes Manifests

| No | Name | Version | Project |
|----|------|---------|---------|
EOF

# Generate manifest components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    
    # Check if it's a manifest component
    category=$(categorize_component "$source_url")
    if [[ "$category" == "manifest" ]]; then
        version=$(extract_version "$path")
        echo "| $counter | $component | $version | $project_url |" >> "$SBOM_FILE"
        ((counter++))
    fi
done

# Add Container Images section placeholder
cat >> "$SBOM_FILE" << 'EOF'

## Container Images

*Container image analysis would require parsing manifest files and Helm charts.*

EOF

echo "SBOM.md generated successfully!"