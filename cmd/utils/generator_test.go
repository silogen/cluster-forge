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

	GenerateFunctionTemplates(inputDir, outputFilePath)

	outputContent, err := ioutil.ReadFile(outputFilePath)
	if err != nil {
		t.Fatalf("Failed to read output file: %v", err)
	}

	var runtimeConfig DeploymentRuntimeConfig
	if err := yaml.Unmarshal(outputContent, &runtimeConfig); err != nil {
		t.Fatalf("Failed to unmarshal output YAML: %v", err)
	}

	if runtimeConfig.Metadata.Name != "mount-templates" {
		t.Errorf("Expected metadata name 'mount-templates', got '%s'", runtimeConfig.Metadata.Name)
	}

	if len(runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers) != 1 {
		t.Errorf("Expected 1 container, got %d", len(runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers))
	}

	volumeMounts := runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers[0].VolumeMounts
	if len(volumeMounts) != 1 || volumeMounts[0].Name != "example-configmap" {
		t.Errorf("Expected volume mount for 'example-configmap', got %+v", volumeMounts)
	}

	volumes := runtimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Volumes
	if len(volumes) != 1 || volumes[0].Name != "example-configmap" {
		t.Errorf("Expected volume for 'example-configmap', got %+v", volumes)
	}

	for _, volume := range volumes {
		if volume.Name == "invalid-configmap" {
			t.Fatalf("Unexpected volume created for invalid ConfigMap")
		}
	}
}
