package miner

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/silogen/cluster-forge/cmd/utils"
	"github.com/silogen/cluster-forge/cmd/utils/configloader"
	"gopkg.in/yaml.v3"
)

func Mine(configs configloader.ToolSet) {
	for _, config := range configs {
		sourceYamlPath := fmt.Sprintf("input/%s/source.yaml", config.Name)
		data, err := os.ReadFile(sourceYamlPath)
		if err != nil {
			// no source.yaml, skip
			continue
		}
		log.Println("Source: " + config.Name)
		err = handleSource(data)
		if err != nil {
			log.Fatalf("Handling of source failed: %v", err)
		}
	}
}

func handleSource(sourceBytes []byte) error {
	var source utils.Config
	err := yaml.Unmarshal(sourceBytes, &source)
	if err != nil {
		return fmt.Errorf("unmarshaling of source failed: %v", err)
	}
	err = validateSources(source)
	if err != nil {
		return fmt.Errorf("invalid source %s: %v", source.Name, err)
	}
	tempFile, err := os.CreateTemp("", "example.*.txt")
	if err != nil {
		return fmt.Errorf("failed to create tempfile: %v", err)
	}
	defer os.Remove(tempFile.Name())
	source.Filename = tempFile.Name()

	err = utils.Templatehelm(source, &utils.DefaultHelmExecutor{})

	if err != nil {
		return fmt.Errorf("failed to read source: %v", err)
	}
	manifestTargetPath := fmt.Sprintf("input/%s/manifests/sourced", source.Name)
	os.RemoveAll(manifestTargetPath)

	utils.SplitYAML(source, manifestTargetPath)
	err = utils.CreateConfigmapFile(source, string(sourceBytes), manifestTargetPath)
	for _, manifestFile := range source.SourceExclusions {
		os.RemoveAll(filepath.Join(manifestTargetPath, manifestFile))
	}
	if err != nil {
		return fmt.Errorf("failed to create ConfigMap: %v", err)
	}
	return nil
}

func validateSources(source utils.Config) error {
	if source.Name == "" {
		return fmt.Errorf("missing 'name' in config: %+v", source)
	}
	if source.Namespace == "" {
		return fmt.Errorf("missing 'namespace' in config: %+v", source)
	}
	if source.ManifestURL == "" && source.HelmChartName == "" {
		return fmt.Errorf("either 'manifest-url' or 'helm-chart-name' must be provided in config: %+v", source)
	}
	if source.HelmChartName != "" {
		if source.HelmName == "" {
			return fmt.Errorf("missing 'helm-name' in config with 'helm-chart-name': %+v", source)
		}
	}
	return nil
}
