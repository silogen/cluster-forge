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
			Name:        "amd-device-plugin",
			Namespace:   "kube-system",
			ManifestURL: "https://raw.githubusercontent.com/ROCm/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml",
		},
	}

	failureConfigs := []utils.Config{
		{
			Name:      "certmanager",
			Namespace: "cert-manager",
		},
	}

	// Use permanent paths for debugging
	workingDir := "./debug/working"
	outputDir := "./debug/output"
	stacksDir := "./debug/stacks"

	// Clean up and create directories
	if err := os.RemoveAll(workingDir); err != nil {
		t.Fatalf("Failed to clean up working directory: %v", err)
	}
	if err := os.MkdirAll(workingDir, 0755); err != nil {
		t.Fatalf("Failed to create working directory: %v", err)
	}

	if err := os.RemoveAll(outputDir); err != nil {
		t.Fatalf("Failed to clean up output directory: %v", err)
	}
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		t.Fatalf("Failed to create output directory: %v", err)
	}

	if err := os.RemoveAll(stacksDir); err != nil {
		t.Fatalf("Failed to clean up stacks directory: %v", err)
	}
	if err := os.MkdirAll(stacksDir, 0755); err != nil {
		t.Fatalf("Failed to create stacks directory: %v", err)
	}

	err := smelter.PrepareTool(successConfigs, []string{"amd-device-plugin"}, workingDir)
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

	caster.Cast(successConfigs, outputDir, workingDir, stacksDir)
	if err != nil {
		t.Fatalf("castTool failed: %v", err)
	}

	if _, err := os.Stat(outputDir); os.IsNotExist(err) {
		if err := os.MkdirAll(outputDir, 0755); err != nil {
			t.Fatalf("Failed to create outputDir: %v", err)
		}
	}

	expectedOutputs := []string{
		filepath.Join(outputDir, "cm-amd-device-plugin-object-1.yaml"),
	}

	for _, outputFile := range expectedOutputs {
		if _, err := os.Stat(outputFile); os.IsNotExist(err) {
			t.Errorf("Expected output file '%s' to be created", outputFile)
		}
	}
}
