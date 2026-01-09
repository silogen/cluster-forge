#!/bin/bash

set -euo pipefail

# validate-sync.sh - Comprehensive SBOM sync validator
# Orchestrates all validation checks to ensure values.yaml and components.yaml are in sync
# Used by both human developers and CI/CD workflow

echo "🛡️ SBOM Sync Validation"
echo "Running comprehensive validation checks..."
echo ""

# Run individual validation scripts in sequence
echo "Step 1/3: EnabledApps Consistency Check"
./validate-enabled-apps.sh

echo ""
echo "Step 2/3: Components Sync Check"
./validate-components-sync.sh

echo ""
echo "Step 3/3: Metadata Completeness Check"
./validate-metadata.sh

echo ""
echo "🎉 SUCCESS! All SBOM sync validations passed!"
echo "✅ values.yaml and components.yaml are properly synchronized"
echo "✅ All required metadata fields are populated"
echo ""
echo "Your changes are ready for commit and PR!"# Test comment
