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
	const usePermanentPaths = false

	workingDir := "./debug/working"
	outputDir := "./debug/output"
	stacksDir := "./debug/stacks"

	if !usePermanentPaths {
		var err error
		workingDir, err = os.MkdirTemp("", "working-*")
		if err != nil {
			t.Fatalf("Failed to create temporary working directory: %v", err)
		}
		defer os.RemoveAll(workingDir)

		outputDir, err = os.MkdirTemp("", "output-*")
		if err != nil {
			t.Fatalf("Failed to create temporary output directory: %v", err)
		}
		defer os.RemoveAll(outputDir)

		stacksDir, err = os.MkdirTemp("", "stacks-*")
		if err != nil {
			t.Fatalf("Failed to create temporary stacks directory: %v", err)
		}
		defer os.RemoveAll(stacksDir)
	} else {
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
	}

	err := smelter.PrepareTool(successConfigs, []string{"amd-device-plugin"}, workingDir)
	if err != nil {
		t.Fatalf("PrepareTool failed: %v", err)
	}

	for _, config := range successConfigs {
		namespaceFile := filepath.Join(workingDir, config.Name, "Namespace_"+config.Name+".yaml")
		if _, err := os.Stat(namespaceFile); os.IsNotExist(err) {
			t.Errorf("Expected namespace file '%s' to be created", namespaceFile)
		}
	}

	castname := "test-stack"
	toolTypes := []string{"amd-device-plugin"}

	err = caster.CastTool(successConfigs, toolTypes, outputDir, workingDir)
	if err != nil {
		t.Fatalf("CastTool failed: %v", err)
	}

	caster.PreparePackageDirectory(stacksDir, castname)

	caster.CopyFilesWithSpinner(outputDir, filepath.Join(stacksDir, castname))

	expectedOutputs := []string{
		filepath.Join(outputDir, "cm-amd-device-plugin-object-1.yaml"),
	}

	for _, outputFile := range expectedOutputs {
		if _, err := os.Stat(outputFile); os.IsNotExist(err) {
			t.Errorf("Expected output file '%s' to be created", outputFile)
		}
	}

	expectedStackFile := filepath.Join(stacksDir, castname, "cm-amd-device-plugin-object-1.yaml")
	if _, err := os.Stat(expectedStackFile); os.IsNotExist(err) {
		t.Errorf("Expected stack file '%s' to be created", expectedStackFile)
	}
}
