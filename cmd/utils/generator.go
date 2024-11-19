package utils

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v2"
)

type Namespace struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
}

type ConfigMap struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
}

type VolumeMount struct {
	MountPath string `yaml:"mountPath"`
	Name      string `yaml:"name"`
	ReadOnly  bool   `yaml:"readOnly"`
}

type Volume struct {
	Name      string `yaml:"name"`
	ConfigMap struct {
		Name string `yaml:"name"`
	} `yaml:"configMap"`
}

type Container struct {
	Name         string        `yaml:"name"`
	VolumeMounts []VolumeMount `yaml:"volumeMounts"`
}

type PodSpec struct {
	Containers []Container `yaml:"containers"`
	Volumes    []Volume    `yaml:"volumes"`
}

type TemplateSpec struct {
	Spec PodSpec `yaml:"spec"`
}

type DeploymentTemplate struct {
	Spec struct {
		Selector map[string]string `yaml:"selector"`
		Template TemplateSpec      `yaml:"template"`
	} `yaml:"spec"`
}

type Spec struct {
	DeploymentTemplate DeploymentTemplate `yaml:"deploymentTemplate"`
}

type DeploymentRuntimeConfig struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
	Spec Spec `yaml:"spec"`
}

func GenerateFunctionTemplates(outputDir string, newFilePath string) {
	files, err := os.ReadDir(outputDir)
	if err != nil {
		log.Fatalf("failed reading directory: %s", err)
	}

	// Initialize DeploymentRuntimeConfig structure
	deploymentRuntimeConfig := &DeploymentRuntimeConfig{
		APIVersion: "pkg.crossplane.io/v1beta1",
		Kind:       "DeploymentRuntimeConfig",
		Metadata: struct {
			Name string `yaml:"name"`
		}{
			Name: "mount-templates",
		},
		Spec: Spec{
			DeploymentTemplate: DeploymentTemplate{
				Spec: struct {
					Selector map[string]string `yaml:"selector"`
					Template TemplateSpec      `yaml:"template"`
				}{
					Selector: map[string]string{},
					Template: TemplateSpec{
						Spec: PodSpec{
							Containers: []Container{
								{
									Name: "package-runtime",
								},
							},
						},
					},
				},
			},
		},
	}

	// Iterate over files in the directory and create volume mounts and volumes as needed
	for _, file := range files {
		if strings.HasSuffix(file.Name(), ".yaml") {
			filePath := filepath.Join(outputDir, file.Name())
			content, err := os.ReadFile(filePath)
			if err != nil {
				log.Fatalf("failed reading file: %s", err)
			}

			var configMap ConfigMap
			err = yaml.Unmarshal(content, &configMap)
			if err != nil {
				log.Fatalf("failed unmarshalling yaml: %s", err)
			}

			if configMap.Kind == "ConfigMap" {
				// Create a specific volume mount and volume for each discovered configMap
				volumeMount := VolumeMount{
					MountPath: fmt.Sprintf("/templates/%s", configMap.Metadata.Name),
					Name:      configMap.Metadata.Name,
					ReadOnly:  true,
				}
				volume := Volume{
					Name: configMap.Metadata.Name,
					ConfigMap: struct {
						Name string `yaml:"name"`
					}{
						Name: configMap.Metadata.Name,
					},
				}

				// Append the volume mount and volume to the spec
				deploymentRuntimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers[0].VolumeMounts = append(deploymentRuntimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Containers[0].VolumeMounts, volumeMount)
				deploymentRuntimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Volumes = append(deploymentRuntimeConfig.Spec.DeploymentTemplate.Spec.Template.Spec.Volumes, volume)
			}
		}
	}

	// Marshal the deploymentRuntimeConfig to YAML
	updatedContent, err := yaml.Marshal(deploymentRuntimeConfig)
	if err != nil {
		log.Fatalf("failed marshalling updated spec: %s", err)
	}

	// Write the updated YAML to a new file
	err = os.WriteFile(newFilePath, updatedContent, os.ModePerm)
	if err != nil {
		log.Fatalf("failed writing updated file: %s", err)
	}

	log.Debug("New volume structure written to %s\n", newFilePath)
}

func CopyYAMLFiles(srcDir, destDir string) error {
	files, err := filepath.Glob(filepath.Join(srcDir, "*.yaml"))
	if err != nil {
		return fmt.Errorf("failed to list YAML files: %w", err)
	}

	for _, srcPath := range files {
		destPath := filepath.Join(destDir, filepath.Base(srcPath))

		srcFile, err := os.Open(srcPath)
		if err != nil {
			return fmt.Errorf("failed to open source file: %w", err)
		}
		defer srcFile.Close()

		destFile, err := os.Create(destPath)
		if err != nil {
			return fmt.Errorf("failed to create destination file: %w", err)
		}
		defer destFile.Close()

		_, err = io.Copy(destFile, srcFile)
		if err != nil {
			return fmt.Errorf("failed to copy file: %w", err)
		}
	}

	return nil
}
func RemoveYAMLFiles(dir string) error {
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return fmt.Errorf("failed to list YAML files: %w", err)
	}

	for _, filePath := range files {
		err := os.Remove(filePath)
		if err != nil {
			return fmt.Errorf("failed to remove file: %w", err)
		}
	}

	return nil
}

func ProcessNamespaceFiles(dir string) error {
	namespaceMap := make(map[string]struct{})

	// Iterate over all files named namespace-*
	files, err := filepath.Glob(filepath.Join(dir, "namespace-*"))
	if err != nil {
		return err
	}

	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}

		var ns Namespace
		err = yaml.Unmarshal(data, &ns)
		if err != nil {
			return err
		}

		// Check if the namespace already exists in the map
		if _, exists := namespaceMap[ns.Metadata.Name]; exists || ns.Metadata.Name == "kube-system" || ns.Metadata.Name == "default" {
			// Delete the duplicate file
			err = os.Remove(file)
			if err != nil {
				return err
			}
		} else {
			// Add the namespace name to the map
			namespaceMap[ns.Metadata.Name] = struct{}{}
		}
	}

	return nil
}
