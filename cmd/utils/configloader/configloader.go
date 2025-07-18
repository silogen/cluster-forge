/**
 * Copyright 2025 Advanced Micro Devices, Inc.  All rights reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
**/

package configloader

import (
	"fmt"
	"os"
	"strconv"

	"github.com/charmbracelet/huh"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v3"
)

type configAsMap map[string]interface{}

type ToolSet map[string]utils.Config

func expandCollection(tool utils.Config, defaults ToolSet) ToolSet {
	tools := make(ToolSet)
	if len(tool.Collection) == 0 {
		tools[tool.Name] = tool
	} else {
		additionalTools := make(ToolSet)
		for _, member := range tool.Collection {
			if _, exists := defaults[member]; exists {
				additionalTools[member] = defaults[member]
			}
		}
		for name, config := range expandSelections(additionalTools, defaults) {
			tools[name] = config
		}
	}
	return tools
}

// expandSelections processes tool selections and returns expanded list including collection members
func expandSelections(selections ToolSet, defaults ToolSet) ToolSet {
	tools := make(ToolSet)
	for tool, config := range selections {
		defaultConfig, exists := defaults[tool]
		if !exists {
			tools[tool] = config
			continue
		}
		for name, config := range expandCollection(defaultConfig, defaults) {
			tools[name] = config
		}
	}
	return tools
}
func makeToolset(filename string, gitops utils.GitopsParameters) (ToolSet, []utils.Config, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, nil, err
	}
	var configs []utils.Config
	err = yaml.Unmarshal(data, &configs)
	if err != nil {
		return nil, nil, err
	}
	toolset := make(ToolSet)
	for _, config := range configs {
		config.GitopsUrl = gitops.Url
		config.GitopsBranch = gitops.Branch
		config.GitopsPathPrefix = gitops.PathPrefix
		toolset[config.Name] = config
	}
	return toolset, configs, nil
}

func chooseTools(defaultTools ToolSet, configs []utils.Config) (ToolSet, error) {
	var selections ToolSet

	var names []string
	var choices []string
	names = append(names, "all")
	for _, config := range configs {
		names = append(names, config.Name)
	}
	accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))

	log.Info("starting up the menu...")
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Options(huh.NewOptions(names...)...).
				Title("Choose your target tools to smelt").
				Validate(func(t []string) error {
					if len(t) <= 0 {
						return fmt.Errorf("at least one tool is required")
					}
					return nil
				}).
				Value(&choices).
				Filterable(true),
		),
	).WithAccessible(accessible)

	err := form.Run()
	if err != nil {
		log.Fatal("Uh oh:", err)
	}

	if len(choices) > 0 && choices[0] == "all" {
		selections = defaultTools
	} else {
		selections = make(ToolSet)
		for _, name := range choices {
			selections[name] = defaultTools[name]
		}
	}
	return selections, nil
}

func mergeInputValues(expandedSelections ToolSet, inputs ToolSet) (ToolSet, error) {
	selections := make(ToolSet)

	for name, config := range expandedSelections {
		_, ok := inputs[name]

		if !ok {
			// No changes to values in inputs
			selections[name] = expandedSelections[name]
		}
		var inputMap configAsMap
		var selectionMap configAsMap
		yamlBytes, _ := yaml.Marshal(config)
		err := yaml.Unmarshal(yamlBytes, &selectionMap)
		if err != nil {
			return nil, err
		}
		yamlBytes, _ = yaml.Marshal(inputs[name])
		err = yaml.Unmarshal(yamlBytes, &inputMap)
		if err != nil {
			return nil, err
		}
		for key, val := range inputMap {
			switch v := val.(type) {
			default:
				log.Fatalf("Type %v not understood by loader", v)
			case []interface{}:
				if len(val.([]interface{})) > 0 {
					selectionMap[key] = val
				}
			case string:
				if val.(string) != "" {
					selectionMap[key] = val
				}
			}
		}

		var combinedConfig utils.Config
		combinedYaml, err := yaml.Marshal(selectionMap)
		if err != nil {
			return nil, err
		}
		err = yaml.Unmarshal(combinedYaml, &combinedConfig)
		if err != nil {
			return nil, err
		}
		selections[name] = combinedConfig
	}
	return selections, nil
}

func LoadConfig(filename string, defaultFilename string, gitops utils.GitopsParameters, nonInteractive bool) (ToolSet, error) {
	defaultTools, toolList, err := makeToolset(defaultFilename, gitops)
	if err != nil {
		return nil, err
	}
	var inputs ToolSet
	if filename != defaultFilename || nonInteractive {
		inputs, _, err = makeToolset(filename, gitops)
		if err != nil {
			return nil, err
		}
	} else {
		inputs, err = chooseTools(defaultTools, toolList)
		if err != nil {
			return nil, err
		}
	}
	expandedSelections := expandSelections(inputs, defaultTools)
	selections, err := mergeInputValues(expandedSelections, inputs)
	if err != nil {
		return nil, err
	}
	err = validateConfig(selections)
	if err != nil {
		return nil, err
	}
	return selections, nil
}

func validateConfig(configs ToolSet) error {
	for _, config := range configs {
		// Skip validation for collection entries
		if len(config.Collection) > 0 {
			// Only validate that name is present for collections
			if config.Name == "" {
				return fmt.Errorf("missing 'name' in collection config: %+v", config)
			}
			continue
		}
		if config.Name == "" {
			return fmt.Errorf("missing 'name' in config: %+v", config)
		}
		// Only require namespace for helm charts, since manifest-based tools
		// might already define their own namespaces in the manifests
		if config.HelmChartName != "" && config.Namespace == "" && len(config.Namespaces) == 0 {
			return fmt.Errorf("either 'namespace' or 'namespaces' must be provided for helm charts in config: %+v", config)
		}
		if config.ManifestURL == "" && config.HelmChartName == "" && len(config.ManifestPath) == 0 {
			return fmt.Errorf("either 'manifest-url', 'helm-chart-name' or 'manifestpath' must be provided in config: %+v", config)
		}
		if config.HelmChartName != "" {
			if config.HelmName == "" {
				return fmt.Errorf("missing 'helm-name' in config with 'helm-chart-name': %+v", config)
			}
		}
	}
	return nil
}
