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

			testFilePath := filepath.Join(workingDir, "CustomResourceDefinition_test.yaml")
			err = os.WriteFile(testFilePath, []byte("---\nkind: CustomResourceDefinition\nmetadata:\n  name: test-crd\n"), 0644)
			if err != nil {
				t.Fatalf("Failed to create test input file: %v", err)
			}

			t.Logf("Running CreateCrossplaneObject for %s...", tt.name)
			defer func() {
				if r := recover(); r != nil && !tt.shouldFail {
					t.Fatalf("Unexpected panic: %v", r)
				}
			}()
			err = CreateCrossplaneObject(tt.config, outputDir, "../../tests/test_data")

			if tt.shouldFail {
				if err == nil {
					t.Fatalf("Expected CreateCrossplaneObject to fail for test case '%s', but it succeeded", tt.name)
				}
				t.Logf("Expected failure: %v", err)
				return
			}

			if err != nil {
				t.Fatalf("CreateCrossplaneObject failed unexpectedly: %v", err)
			}

			expectedOutputFile := filepath.Join(outputDir, "crd-"+tt.config.Name+"-1.yaml")
			if _, err := os.Stat(expectedOutputFile); err != nil {
				t.Fatalf("Expected output file %s not found: %v", expectedOutputFile, err)
			}

			outputContent, err := os.ReadFile(expectedOutputFile)
			if err != nil {
				t.Fatalf("Failed to read output file %s: %v", expectedOutputFile, err)
			}
			if string(outputContent) == "" {
				t.Fatalf("Output file %s is empty", expectedOutputFile)
			}

			t.Logf("Test case '%s' passed", tt.name)
		})
	}
}
