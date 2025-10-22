#!/bin/bash

# Script to update empty license fields in components.yaml with GitHub license information
# Uses the same GitHub API fetching logic as get_github_licenses.sh

COMPONENTS_FILE="components.yaml"

if [[ ! -f "$COMPONENTS_FILE" ]]; then
    echo "Error: $COMPONENTS_FILE not found"
    exit 1
fi

# Check if required tools are available
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

echo "Updating license information in $COMPONENTS_FILE..."
echo "=================================================="


# Function to fetch license info from GitHub API (same logic as get_github_licenses.sh)
fetch_github_license() {
    local project_url="$1"
    
    # Extract owner/repo from GitHub URL
    if [[ "$project_url" =~ github\.com/([^/]+)/([^/]+) ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        
        # Remove trailing slash if present
        repo="${repo%/}"
        
        echo "  Fetching license info from GitHub API for $owner/$repo..." >&2
        
        # Fetch license information from GitHub API
        local license_info=$(curl -s "https://api.github.com/repos/$owner/$repo/license" | jq -r '.')
        
        if [[ "$license_info" == "null" ]]; then
            echo "  No license detected for $owner/$repo" >&2
            return 1
        else
            local license_name=$(echo "$license_info" | jq -r '.license.name // "Unknown"')
            local license_html_url=$(echo "$license_info" | jq -r '.html_url // ""')
            
            if [[ -n "$license_html_url" && "$license_html_url" != "null" ]]; then
                echo "  Found: $license_name - $license_html_url" >&2
                echo "$license_name|$license_html_url"
                return 0
            else
                echo "  Found: $license_name (no URL available)" >&2
                echo "$license_name|"
                return 0
            fi
        fi
    else
        echo "  Not a GitHub URL or invalid format: $project_url" >&2
        return 1
    fi
}

# Parse YAML and process each component
yq eval '.components | to_entries | .[] | [.key, .value.projectUrl // "", .value.license // "", .value.licenseUrl // ""] | @csv' "$COMPONENTS_FILE" | \
while IFS=',' read -r component_name project_url current_license current_license_url; do
    # Remove quotes from CSV output
    component_name=$(echo "$component_name" | tr -d '"')
    project_url=$(echo "$project_url" | tr -d '"')
    current_license=$(echo "$current_license" | tr -d '"')
    current_license_url=$(echo "$current_license_url" | tr -d '"')
    
    echo "Processing component: $component_name"
    
    # Check if we should update (always update if license URL is a generic API URL)
    should_update=false
    if [[ -z "$current_license" || -z "$current_license_url" ]]; then
        should_update=true
        echo "  Empty license fields detected, will update"
    elif [[ "$current_license_url" =~ ^https://api\.github\.com/licenses/ ]]; then
        should_update=true
        echo "  Generic API license URL detected, will update to actual repository URL"
    else
        echo "  License already populated with repository URL: $current_license"
        echo "  License URL: $current_license_url"
        echo "  Skipping..."
        echo ""
        continue
    fi
    
    # Skip if no project URL or not a GitHub URL
    if [[ -z "$project_url" ]] || [[ ! "$project_url" =~ github\.com ]]; then
        echo "  No GitHub project URL found, skipping..."
        echo ""
        continue
    fi
    
    # Fetch license information from GitHub
    if license_result=$(fetch_github_license "$project_url"); then
        IFS='|' read -r license_name license_url <<< "$license_result"
        
        # Update license field
        echo "  Updating license field: '$license_name'"
        yq eval ".components.$component_name.license = \"$license_name\"" -i "$COMPONENTS_FILE"
        
        # Update licenseUrl field if we have a URL
        if [[ -n "$license_url" ]]; then
            echo "  Updating licenseUrl field: '$license_url'"
            yq eval ".components.$component_name.licenseUrl = \"$license_url\"" -i "$COMPONENTS_FILE"
        fi
        
        echo "  ✓ Updated successfully"
    else
        echo "  ✗ Failed to fetch license information"
    fi
    
    echo ""
done

echo "License update completed!"
echo ""
