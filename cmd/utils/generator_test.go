package utils

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestGenerateFunctionTemplates(t *testing.T) {
	inputDir, err := ioutil.TempDir("", "input")
	if err != nil {
		t.Fatalf("Failed to create temporary input directory: %v", err)
	}
	defer os.RemoveAll(inputDir)

	outputDir, err := ioutil.TempDir("", "output")
	if err != nil {
		t.Fatalf("Failed to create temporary output directory: %v", err)
	}
	defer os.RemoveAll(outputDir)

	// Valid ConfigMap
	configMap := `
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-configmap
`
	inputFilePath := filepath.Join(inputDir, "example-configmap.yaml")
	if err := ioutil.WriteFile(inputFilePath, []byte(configMap), 0644); err != nil {
		t.Fatalf("Failed to write ConfigMap YAML file: %v", err)
	}

	// Invalid ConfigMap (missing name)
	invalidConfigMap := `
apiVersion: v1
kind: ConfigMap
metadata:
  # name is missing
`
	invalidFilePath := filepath.Join(inputDir, "invalid-configmap.yaml")
	if err := ioutil.WriteFile(invalidFilePath, []byte(invalidConfigMap), 0644); err != nil {
		t.Fatalf("Failed to write invalid ConfigMap YAML file: %v", err)
	}

	outputFilePath := filepath.Join(outputDir, "deployment-runtime-config.yaml")

	// Run the function
	GenerateFunctionTemplates(inputDir, outputFilePath)

	outputContent, err := ioutil.ReadFile(outputFilePath)
	if err != nil {
		t.Fatalf("Failed to read output file: %v", err)
	}

	// t.Logf("Generated YAML content:\n%s", string(outputContent))

	var runtimeConfig DeploymentRuntimeConfig
	if err := yaml.Unmarshal(outputContent, &runtimeConfig); err != nil {
		t.Fatalf("Failed to unmarshal output YAML: %v", err)
	}

	// Validate metadata name
	if runtimeConfig.Metadata.Name != "mount-templates" {
		t.Errorf("Expected metadata name 'mount-templates', got '%s'", runtimeConfig.Metadata.Name)
	}

	// Validate the number of containers
	if len(runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers) != 1 {
		t.Errorf("Expected 1 container, got %d", len(runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers))
	}

	// Validate volume mounts
	volumeMounts := runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers[0].VolumeMounts
	if len(volumeMounts) != 2 {
		t.Errorf("Expected 1 volume mount, got %d", len(volumeMounts))
	} else if volumeMounts[0].Name != "example-configmap" || volumeMounts[0].MountPath != "/templates/example-configmap" {
		t.Errorf("Unexpected volume mount: %+v", volumeMounts[0])
	}

	// Validate volumes
	volumes := runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Volumes
	if len(volumes) != 2 {
		t.Errorf("Expected 1 volume, got %d", len(volumes))
	} else if volumes[0].Name != "example-configmap" || volumes[0].ConfigMap.Name != "example-configmap" {
		t.Errorf("Unexpected volume: %+v", volumes[0])
	}

	// Ensure no volumes are created for invalid ConfigMaps
	for _, volume := range volumes {
		if volume.Name == "invalid-configmap" {
			t.Fatalf("Unexpected volume created for invalid ConfigMap")
		}
	}
}
