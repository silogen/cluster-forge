#!/bin/bash

# Generate Software Bill of Materials (SBOM) from components.yaml
# This script reads components.yaml and creates SBOM.md

set -euo pipefail

COMPONENTS_FILE="components.yaml"
SBOM_FILE="SBOM.md"
SOURCES_DIR="../sources"

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
    local component_name="$1"
    
    # Check if component has valuesFile field - if yes, it's a Helm chart
    local values_file=$(yq eval ".components.\"$component_name\".valuesFile // \"\"" "$COMPONENTS_FILE")
    
    if [[ -n "$values_file" ]]; then
        echo "helm"
    else
        echo "manifest"
    fi
}

# Get all component names using yq
component_names=$(yq eval '.components | keys | .[]' "$COMPONENTS_FILE")

# Start generating SBOM
cat > "$SBOM_FILE" << 'EOF'
# Software Bill of Materials (SBOM) - Complete

## All Components

| No | Name | Version | Project | License |
|----|------|---------|---------|---------|
EOF

# Generate all components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    license=$(yq eval ".components.\"$component\".license // \"\"" "$COMPONENTS_FILE")
    license_url=$(yq eval ".components.\"$component\".licenseUrl // \"\"" "$COMPONENTS_FILE")
    
    # Extract version from path
    version=$(extract_version "$path")
    
    # Format version with sourceUrl link if available
    if [[ -n "$source_url" ]]; then
        version_link="[$version]($source_url)"
    else
        version_link="$version"
    fi
    
    # Format license with licenseUrl link if available
    if [[ -n "$license_url" ]]; then
        license_link="[$license]($license_url)"
    else
        license_link="$license"
    fi
    
    # Add to all components table
    echo "| $counter | $component | $version_link | $project_url | $license_link |" >> "$SBOM_FILE"
    ((counter++))
done

# Add Helm Charts section
cat >> "$SBOM_FILE" << 'EOF'

## Helm Charts

| No | Name | Version | Project | License |
|----|------|---------|---------|---------|
EOF

# Generate helm components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    license=$(yq eval ".components.\"$component\".license // \"\"" "$COMPONENTS_FILE")
    license_url=$(yq eval ".components.\"$component\".licenseUrl // \"\"" "$COMPONENTS_FILE")
    
    # Check if it's a helm component
    category=$(categorize_component "$component")
    if [[ "$category" == "helm" ]]; then
        version=$(extract_version "$path")
        
        # Format version with sourceUrl link if available
        if [[ -n "$source_url" ]]; then
            version_link="[$version]($source_url)"
        else
            version_link="$version"
        fi
        
        # Format license with licenseUrl link if available
        if [[ -n "$license_url" ]]; then
            license_link="[$license]($license_url)"
        else
            license_link="$license"
        fi
        
        echo "| $counter | $component | $version_link | $project_url | $license_link |" >> "$SBOM_FILE"
        ((counter++))
    fi
done

# Add Kubernetes Manifests section
cat >> "$SBOM_FILE" << 'EOF'

## Kubernetes Manifests

| No | Name | Version | Project | License |
|----|------|---------|---------|---------|
EOF

# Generate manifest components table
counter=1
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    project_url=$(yq eval ".components.\"$component\".projectUrl // \"\"" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    license=$(yq eval ".components.\"$component\".license // \"\"" "$COMPONENTS_FILE")
    license_url=$(yq eval ".components.\"$component\".licenseUrl // \"\"" "$COMPONENTS_FILE")
    
    # Check if it's a manifest component
    category=$(categorize_component "$component")
    if [[ "$category" == "manifest" ]]; then
        version=$(extract_version "$path")
        
        # Format version with sourceUrl link if available
        if [[ -n "$source_url" ]]; then
            version_link="[$version]($source_url)"
        else
            version_link="$version"
        fi
        
        # Format license with licenseUrl link if available
        if [[ -n "$license_url" ]]; then
            license_link="[$license]($license_url)"
        else
            license_link="$license"
        fi
        
        echo "| $counter | $component | $version_link | $project_url | $license_link |" >> "$SBOM_FILE"
        ((counter++))
    fi
done

# Function to extract images from a component
extract_images_for_component() {
    local component_name="$1"
    local component_path="$2"
    
    echo "" >> "$SBOM_FILE"
    echo "## $component_name images" >> "$SBOM_FILE"
    echo "" >> "$SBOM_FILE"
    
    # Find all YAML files in the component path
    local yaml_files=$(find "$SOURCES_DIR/$component_path" -name "*.yaml" -o -name "*.yml" 2>/dev/null || true)
    
    if [ -z "$yaml_files" ]; then
        echo "No container images found in manifest files." >> "$SBOM_FILE"
        return 0
    fi
    
    # Extract container images
    local images=$(grep -h -E "^[[:space:]]*image:" $yaml_files 2>/dev/null | \
                   grep -v "description:" | \
                   grep -v "type: string" | \
                   sed 's/^[[:space:]]*image:[[:space:]]*//' | \
                   sed 's/[[:space:]]*$//' | \
                   sed 's/^"//' | \
                   sed 's/"$//' | \
                   sort -u | \
                   grep -v '^$' || true)
    
    if [ -n "$images" ]; then
        echo "| No | Image |" >> "$SBOM_FILE"
        echo "|----|-------|" >> "$SBOM_FILE"
        
        local counter=1
        echo "$images" | while IFS= read -r image; do
            if [ -n "$image" ]; then
                echo "| $counter | \`$image\` |" >> "$SBOM_FILE"
                counter=$((counter + 1))
            fi
        done
    else
        echo "No container images found in manifest files." >> "$SBOM_FILE"
    fi
}

# Add Container Images section
cat >> "$SBOM_FILE" << 'EOF'

## Container Images

EOF

# Extract images for each component - only manifest components
for component in $component_names; do
    path=$(yq eval ".components.\"$component\".path" "$COMPONENTS_FILE")
    source_url=$(yq eval ".components.\"$component\".sourceUrl // \"\"" "$COMPONENTS_FILE")
    
    # Only process components that are categorized as manifest (appear in Kubernetes Manifests table)
    category=$(categorize_component "$component")
    if [[ "$category" == "manifest" ]]; then
        extract_images_for_component "$component" "$path"
    fi
done

echo "SBOM.md generated successfully!"