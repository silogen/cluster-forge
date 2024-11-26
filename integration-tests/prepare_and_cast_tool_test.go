package integration_tests

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/silogen/cluster-forge/cmd/caster"
	"github.com/silogen/cluster-forge/cmd/smelter"
	"github.com/silogen/cluster-forge/cmd/utils"
)

func TestIntegrationPrepareAndCastTool(t *testing.T) {
	successConfigs := []utils.Config{
		{
			Name:        "kueue",
			Namespace:   "kueue-system",
			ManifestURL: "https://github.com/kubernetes-sigs/kueue/releases/download/v0.8.4/manifests.yaml",
		},
		{
			Name:       "amd-metrics-exporter",
			Namespace:  "monitoring",
			SourceFile: "amd-metrics-exporter/metrics-exporter.yaml",
		},
		{
			HelmChartName: "external-secrets",
			HelmName:      "external-secrets",
			HelmURL:       "https://charts.external-secrets.io",
			Values:        "external-secrets-values.yaml",
			Secrets:       false,
			Name:          "external-secrets",
			Namespace:     "external-secrets",
			HelmVersion:   "0.10.3",
		},
	}

	failureConfigs := []utils.Config{
		{
			Name:      "certmanager",
			Namespace: "cert-manager",
		},
	}

	workingDir, err := os.MkdirTemp("", "working-*")
	if err != nil {
		t.Fatalf("Failed to create temporary working directory: %v", err)
	}
	defer os.RemoveAll(workingDir)

	outputDir, err := os.MkdirTemp("", "output-*")
	if err != nil {
		t.Fatalf("Failed to create temporary output directory: %v", err)
	}
	defer os.RemoveAll(outputDir)

	for _, config := range successConfigs {
		configDir := filepath.Join(workingDir, config.Name)
		if err := os.MkdirAll(configDir, 0755); err != nil {
			t.Fatalf("Failed to create working directory for %s: %v", config.Name, err)
		}

		mockFilePath := filepath.Join(configDir, "CustomResourceDefinition_test.yaml")
		err := os.WriteFile(mockFilePath, []byte("---\nkind: CustomResourceDefinition\nmetadata:\n  name: test-crd\n"), 0644)
		if err != nil {
			t.Fatalf("Failed to create mock file for %s: %v", config.Name, err)
		}
	}

	err = smelter.PrepareTool(successConfigs, []string{"kueue", "amd-metrics-exporter", "external-secrets"}, workingDir)
	if err != nil {
		t.Fatalf("prepareTool failed: %v", err)
	}

	for _, config := range successConfigs {
		namespaceFile := filepath.Join(workingDir, config.Name, "Namespace_"+config.Name+".yaml")
		if _, err := os.Stat(namespaceFile); os.IsNotExist(err) {
			t.Errorf("Expected namespace file '%s' to be created", namespaceFile)
		}
	}

	for _, config := range failureConfigs {
		namespaceFile := filepath.Join(workingDir, config.Name, "Namespace_"+config.Name+".yaml")
		if _, err := os.Stat(namespaceFile); err == nil {
			t.Errorf("Namespace file '%s' should not be created for a failing case", namespaceFile)
		}
	}

	err = caster.CastTool(successConfigs, []string{"kueue", "amd-metrics-exporter", "external-secrets"}, outputDir, workingDir)
	if err != nil {
		t.Fatalf("castTool failed: %v", err)
	}

	expectedOutputs := []string{
		filepath.Join(outputDir, "crd-kueue-1.yaml"),
		filepath.Join(outputDir, "object-amd-metrics-exporter-1.yaml"),
		filepath.Join(outputDir, "crd-external-secrets-1.yaml"),
	}

	for _, outputFile := range expectedOutputs {
		if _, err := os.Stat(outputFile); os.IsNotExist(err) {
			t.Errorf("Expected output file '%s' to be created", outputFile)
		}
	}
}
