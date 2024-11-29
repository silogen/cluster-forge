/**
 * Copyright 2024 Advanced Micro Devices, Inc.  All rights reserved.
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

package caster

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

type toolbox struct {
	Targettool targettool
}

type targettool struct {
	Type []string
}

func Cast(configs []utils.Config, filesDir string, workingDir string, stacksDir string) {
	log.Info("Starting up the menu...")

	castname, toolTypes := handleInteractiveForm(workingDir)

	accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))
	err := spinner.New().
		Title("Preparing your stack...").
		Accessible(accessible).
		Action(func() {
			if err := CastTool(configs, toolTypes, filesDir, workingDir); err != nil {
				log.Fatalf("Error during preparation: %v", err)
			}
		}).
		Run()
	if err != nil {
		log.Fatalf("Error during preparation: %v", err)
	}

	packageDir := PreparePackageDirectory(stacksDir, castname)
	CopyFilesWithSpinner(filesDir, packageDir)

	displaySuccessMessage(castname)
}

func handleInteractiveForm(workingDir string) (string, []string) {
	files, err := os.ReadDir(workingDir)
	if err != nil {
		log.Fatalf("Failed to read working directory: %v", err)
	}

	names := []string{"all"}
	uniqueNames := make(map[string]struct{})
	for _, file := range files {
		if file.IsDir() && file.Name() != "pre" {
			if _, exists := uniqueNames[file.Name()]; !exists {
				names = append(names, file.Name())
				uniqueNames[file.Name()] = struct{}{}
			}
		}
	}
	log.Debugf("Options for multi-select: %v", names)

	var castname string
	var toolTypes []string
	re := regexp.MustCompile("^[a-z0-9_-]+$")

	form := huh.NewForm(
		huh.NewGroup(huh.NewText().
			Title("Name of this composition package").
			CharLimit(25).
			Validate(func(input string) error {
				if !re.MatchString(input) {
					return fmt.Errorf("input can only contain lowercase letters (a-z), digits (0-9), hyphens (-), and underscores (_)")
				}
				return nil
			}).
			Value(&castname)),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Options(huh.NewOptions(names...)...).
				Title("Choose the tools to cast into the stack").
				Validate(func(t []string) error {
					if len(t) <= 0 {
						return fmt.Errorf("at least one tool is required")
					}
					return nil
				}).
				Value(&toolTypes).
				Filterable(true),
		),
	)

	if err := form.Run(); err != nil {
		log.Fatalf("Interactive form failed: %v", err)
	}

	// Handle "all" selection
	if len(toolTypes) > 0 && toolTypes[0] == "all" {
		toolTypes = append(toolTypes, names...)
		toolTypes = removeElement(toolTypes, "all")
	}

	return castname, toolTypes
}

func removeElement(slice []string, element string) []string {
	result := []string{}
	for _, v := range slice {
		if v != element {
			result = append(result, v)
		}
	}
	return result
}

func CastTool(configs []utils.Config, toolTypes []string, filesDir, workingDir string) error {
	// Initialize the configuration map
	configMap := make(map[string]utils.Config)
	for _, config := range configs {
		configMap[config.Name] = config
	}

	var secretFiles []string
	for _, tool := range toolTypes {
		config, exists := configMap[tool]
		if !exists {
			return fmt.Errorf("tool %s not found in config map", tool)
		}

		err := utils.CreateCrossplaneObject(config, filesDir, workingDir)
		if err != nil {
			return fmt.Errorf("failed to create crossplane object for %s: %v", config.Name, err)
		}

		err = utils.ProcessNamespaceFiles(filesDir)
		if err != nil {
			log.Fatalf("Failed to process namespace files for %s: %v", config.Name, err)
		}

		err = utils.RemoveEmptyYAMLFiles(filesDir)
		if err != nil {
			return fmt.Errorf("failed to remove empty YAML files for %s: %v", config.Name, err)
		}

		namespaceFile, crdFile, secretFile, externalSecretFile, objectFile, err := FetchFilesAndCategorizeByPrefix(filesDir, tool)
		if err != nil {
			return fmt.Errorf("failed to fetch and categorize files for %s: %v", config.Name, err)
		}

		config.CRDFiles = append(config.CRDFiles, crdFile...)
		config.NamespaceFiles = append(config.NamespaceFiles, namespaceFile...)
		config.ExternalSecretFiles = append(config.ExternalSecretFiles, externalSecretFile...)
		config.SecretFiles = append(config.SecretFiles, secretFile...)
		config.ObjectFiles = append(config.ObjectFiles, objectFile...)

		configMap[tool] = config

		secretFiles = append(secretFiles, secretFile...)
	}

	if len(secretFiles) != 0 {
		var rawSecrets bool
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("You have secrets which are not converted to ExternalSecrets.\nAre you sure you want to continue?").
					Value(&rawSecrets),
			),
		)

		err := form.Run()
		if err != nil {
			return fmt.Errorf("error during secrets confirmation: %v", err)
		}

		if !rawSecrets {
			return fmt.Errorf("fix secrets and try again")
		}
	}

	return nil
}

func PreparePackageDirectory(stacksDir, castname string) string {
	packageDir := filepath.Join(stacksDir, castname)
	err := os.MkdirAll(packageDir, 0755)
	if err != nil {
		log.Fatalf("Failed to create package directory: %s", err)
	}
	return packageDir
}

func CopyFilesWithSpinner(filesDir, packageDir string) {
	err := spinner.New().
		Title("Copying files to package...").
		Action(func() {
			utils.GenerateFunctionTemplates(filesDir, filepath.Join(filesDir, "function-templates.yaml"))
			err := utils.CopyYAMLFiles("cmd/utils/templates", filesDir)
			if err != nil {
				log.Fatalf("failed to copy YAML files: %s", err)
			}
			files, err := os.ReadDir(filesDir)
			if err != nil {
				log.Fatalf("Failed to read files directory: %v", err)
			}

			for _, file := range files {
				if !file.IsDir() && !strings.HasPrefix(file.Name(), ".") {
					srcPath := filepath.Join(filesDir, file.Name())
					dstPath := filepath.Join(packageDir, file.Name())
					err = utils.CopyFile(srcPath, dstPath)
					if err != nil {
						log.Fatalf("Failed to copy file %s: %v", file.Name(), err)
					}
				}
			}
		}).
		Run()
	if err != nil {
		log.Fatalf("Failed to copy files to package directory: %v", err)
	}
}

func displaySuccessMessage(castname string) {
	var sb strings.Builder
	fmt.Fprintf(&sb,
		"%s\n\nCompleted stack: %s.",
		lipgloss.NewStyle().Bold(true).Render("Cluster Forge"),
		castname,
	)
	fmt.Println(
		lipgloss.NewStyle().
			Width(40).
			BorderStyle(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("63")).
			Padding(1, 2).
			Render(sb.String()),
	)
}

func FetchFilesAndCategorizeByPrefix(dir string, prefix string) (namespaceFiles, crdFiles, secretFiles, externalSecretFiles, objectFiles []string, err error) {
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, nil, nil, nil, err
	}

	for _, file := range files {
		if !file.IsDir() && strings.HasPrefix(file.Name(), prefix) {
			fileName := file.Name()
			if strings.Contains(fileName, "crd") {
				crdFiles = append(crdFiles, fileName)
			} else if strings.Contains(fileName, "externalsecret") {
				externalSecretFiles = append(externalSecretFiles, fileName)
			} else if strings.Contains(fileName, "namespace") {
				namespaceFiles = append(namespaceFiles, fileName)
			} else if strings.Contains(fileName, "secret") {
				secretFiles = append(secretFiles, fileName)
			} else if strings.Contains(fileName, "object") {
				objectFiles = append(objectFiles, fileName)
			}
		}
	}

	return namespaceFiles, crdFiles, secretFiles, externalSecretFiles, objectFiles, nil
}
