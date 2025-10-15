#!/bin/bash

set -euo pipefail

# Script to update components.yaml from values.yaml
# Only updates if there are new items or changes to existing ones
# Preserves existing sourceUrl and projectUrl values

VALUES_FILE="./values.yaml"
OUTPUT_FILE="./components.yaml"
TEMP_FILE="./components.yaml.tmp"

echo "Checking for updates to components.yaml..."

# Check if values.yaml exists
if [[ ! -f "$VALUES_FILE" ]]; then
    echo "Error: $VALUES_FILE not found"
    exit 1
fi

# Get all app names that don't end with -config from values.yaml
app_names=$(yq eval '.apps | keys | .[] | select(. | test("-config$") | not)' "$VALUES_FILE")

# Check if components.yaml exists
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "Creating new $OUTPUT_FILE..."
    needs_update=true
else
    echo "Existing $OUTPUT_FILE found. Checking for changes..."
    needs_update=false
    
    # Check each app from values.yaml
    for app in $app_names; do
        # Get current values from values.yaml
        current_path=$(yq eval ".apps.\"$app\".path" "$VALUES_FILE")
        current_values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$VALUES_FILE")
        
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
fi

if [[ "$needs_update" == "false" ]]; then
    echo "No updates needed. components.yaml is up to date."
    exit 0
fi

echo "Updating $OUTPUT_FILE..."

# Create components.yaml header
cat > "$TEMP_FILE" << 'EOF'
# Generated components metadata for SBOM creation
# This file contains simplified component information extracted from values.yaml
# Apps with "config" suffix are excluded

components:
EOF

# Process each app
for app in $app_names; do
    echo "  $app:" >> "$TEMP_FILE"
    
    # Get path from values.yaml
    path=$(yq eval ".apps.\"$app\".path" "$VALUES_FILE")
    echo "    path: $path" >> "$TEMP_FILE"
    
    # Get valuesFile from values.yaml if it exists
    values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$VALUES_FILE")
    if [[ "$values_file" != "null" ]]; then
        echo "    valuesFile: $values_file" >> "$TEMP_FILE"
    fi
    
    # Preserve existing sourceUrl and projectUrl if they exist, otherwise add empty ones
    if [[ -f "$OUTPUT_FILE" ]]; then
        existing_source_url=$(yq eval ".components.\"$app\".sourceUrl // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        existing_project_url=$(yq eval ".components.\"$app\".projectUrl // \"\"" "$OUTPUT_FILE" 2>/dev/null || echo "")
        
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
    else
        # New file, add empty fields
        echo "    sourceUrl:" >> "$TEMP_FILE"
        echo "    projectUrl:" >> "$TEMP_FILE"
    fi
done

# Replace the original file
mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "Updated $OUTPUT_FILE successfully"
echo ""
echo "Summary of components:"
echo "$app_names" | wc -l | xargs echo "Total components:"
echo ""
echo "Components with valuesFile:"
for app in $app_names; do
    values_file=$(yq eval ".apps.\"$app\".valuesFile // \"null\"" "$VALUES_FILE")
    if [[ "$values_file" != "null" ]]; then
        echo "  - $app"
    fi
done