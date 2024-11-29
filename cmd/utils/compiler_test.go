package utils

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCreateCrossplaneObject(t *testing.T) {
	tests := []struct {
		name       string
		config     Config
		shouldFail bool
	}{
		{
			name: "Valid Helm-based configuration",
			config: Config{
				HelmChartName: "external-secrets",
				HelmURL:       "https://charts.external-secrets.io",
				Secrets:       false,
				Name:          "external-secrets",
				HelmName:      "external-secrets",
				ManifestURL:   "",
				HelmVersion:   "0.10.3",
				Namespace:     "external-secrets",
			},
			shouldFail: false,
		},
		{
			name: "Missing HelmURL (should fail)",
			config: Config{
				HelmChartName: "external-secrets",
				HelmURL:       "",
				Secrets:       false,
				Name:          "external-secrets",
				HelmName:      "external-secrets",
				ManifestURL:   "",
				HelmVersion:   "0.10.3",
				Namespace:     "external-secrets",
			},
			shouldFail: true,
		},
		{
			name: "Empty Namespace (should fail)",
			config: Config{
				HelmChartName: "external-secrets",
				HelmURL:       "https://charts.external-secrets.io",
				Secrets:       false,
				Name:          "external-secrets",
				HelmName:      "external-secrets",
				ManifestURL:   "",
				HelmVersion:   "0.10.3",
				Namespace:     "",
			},
			shouldFail: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			outputDir, err := os.MkdirTemp("", "output-*")
			if err != nil {
				t.Fatalf("Failed to create temporary output directory: %v", err)
			}
			defer os.RemoveAll(outputDir)

			workingDir := filepath.Join("../../tests/test_data", tt.config.Name)
			err = os.MkdirAll(workingDir, 0755)
			if err != nil {
				t.Fatalf("Failed to create temporary working directory: %v", err)
			}
			defer os.RemoveAll(workingDir)

			// Run the function
			err = CreateCrossplaneObject(tt.config, outputDir, workingDir)

			// Verify if the result matches the expected behavior
			if tt.shouldFail {
				if err == nil {
					t.Fatalf("Expected CreateCrossplaneObject to fail for test case '%s', but it succeeded", tt.name)
				}
				t.Logf("Expected failure for test case '%s': %v", tt.name, err)
			} else {
				if err != nil {
					t.Fatalf("CreateCrossplaneObject failed unexpectedly for test case '%s': %v", tt.name, err)
				}
				t.Logf("Test case '%s' passed", tt.name)
			}
		})
	}
}
