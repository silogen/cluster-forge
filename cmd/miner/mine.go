package miner

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"

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
		var source utils.Config
		err = yaml.Unmarshal(data, &source)
		if err != nil {
			log.Fatalf("unmarshaling of source failed: %v", err)
		}
		err = handleSource(source, data, "sourced")
		if err != nil {
			log.Fatalf("Handling of source failed: %v", err)
		}
		err = handleDiffs(source, data)
		if err != nil {
			log.Fatalf("Handling of diffs failed: %v", err)
		}

	}
}

func handleSource(source utils.Config, sourceBytes []byte, targetDir string) error {
	err := validateSources(source)
	if err != nil {
		return fmt.Errorf("invalid source %s: %v", source.Name, err)
	}
	tempFile, err := os.CreateTemp("", "mine.*.yaml")
	if err != nil {
		return fmt.Errorf("failed to create tempfile: %v", err)
	}
	defer os.Remove(tempFile.Name())
	source.Filename = tempFile.Name()

	err = utils.Templatehelm(source, &utils.DefaultHelmExecutor{})

	if err != nil {
		return fmt.Errorf("failed to read source: %v", err)
	}
	manifestTargetPath := fmt.Sprintf("input/%s/manifests/%s", source.Name, targetDir)
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

type Diff struct {
	Name   string `yaml:"diffname"`
	Values string `yaml:"diffvalues"`
}

func handleDiffs(source utils.Config, sourceBytes []byte) error {
	pattern := fmt.Sprintf("input/%s/diff-*.yaml", source.Name)
	files, err := filepath.Glob(pattern)
	if err != nil {
		return err
	}

	if len(files) == 0 {
		return nil
	}

	for _, file := range files {
		diffBytes, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		var diff Diff
		err = yaml.Unmarshal(diffBytes, &diff)
		if err != nil {
			return err
		}
		diffedSource := source
		diffedSource.Values = diff.Values
		err = handleSource(diffedSource, append(sourceBytes, diffBytes...), diff.Name)
		if err != nil {
			return err
		}
		pattern = fmt.Sprintf("input/%s/manifests/%s/*.yaml", source.Name, diff.Name)
		diffManifests, err := filepath.Glob(pattern)
		if err != nil {
			return err
		}
		pattern = fmt.Sprintf("input/%s/manifests/sourced/*.yaml", source.Name)
		sourceManifests, err := filepath.Glob(pattern)
		if err != nil {
			return err
		}
		for _, manifest := range diffManifests {
			sourceFile := fmt.Sprintf("input/%s/manifests/sourced/%s", source.Name, filepath.Base(manifest))
			if !slices.Contains(sourceManifests, sourceFile) {
				continue
			}
			diffData, err := os.ReadFile(manifest)
			if err != nil {
				return err
			}
			sourceData, err := os.ReadFile(sourceFile)
			if err != nil {
				return err
			}
			if string(diffData) == string(sourceData) {
				err := os.Remove(manifest)
				if err != nil {
					return err
				}
			}
		}
	}
	return nil
}
