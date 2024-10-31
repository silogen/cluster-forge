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
	xstrings "github.com/charmbracelet/x/exp/strings"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

type toolbox struct {
	Targettool targettool
}

type targettool struct {
	Type []string
}

// Function to remove a specific element from a slice
func removeElement(slice []string, element string) []string {
	result := []string{}
	for _, v := range slice {
		if v != element {
			result = append(result, v)
		}
	}
	return result
}

// FetchFilesAndCategorize fetches files with the given prefix and categorizes them
func FetchFilesAndCategorize(dir string, prefix string) (crdFiles, secretFiles, externalSecretFiles, objectFiles []string, err error) {
	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, nil, nil, err
	}

	for _, file := range files {
		if !file.IsDir() && strings.HasPrefix(file.Name(), prefix) {
			fileName := file.Name()
			if strings.Contains(fileName, "crd") {
				crdFiles = append(crdFiles, fileName)
			} else if strings.Contains(fileName, "externalsecret") {
				externalSecretFiles = append(externalSecretFiles, fileName)
			} else if strings.Contains(fileName, "secret") {
				secretFiles = append(secretFiles, fileName)
			} else if strings.Contains(fileName, "object") {
				objectFiles = append(objectFiles, fileName)
			}
		}
	}

	return crdFiles, secretFiles, externalSecretFiles, objectFiles, nil
}

func combineFiles(files []string, filesDir string) string {
	var combinedText string
	for _, file := range files {
		// Construct the file path
		filePath := filepath.Join(filesDir, file)

		// Read the content of the file
		content, err := os.ReadFile(filePath)
		if err != nil {
			log.Fatalf("Failed to read file %s: %v", filePath, err)
		}

		// Append the content to the combinedText
		combinedText += string(content)
	}
	return combinedText
}

func Cast(configs []utils.Config) {
	log.Info("starting up the menu...")
	var targettool targettool
	var toolbox = toolbox{Targettool: targettool}
	names := []string{"all"}

	// Directory to search for .yaml files
	outputDir := "./working"

	// List all files in the output directory
	files, err := os.ReadDir(outputDir)
	if err != nil {
		log.Errorf("Failed to read directory: %v\n", err)
		return
	}

	// Filter all .yaml files and ensure names are unique
	uniqueNames := make(map[string]struct{})
	castname := ""
	for _, file := range files {
		if file.IsDir() && file.Name() != "pre" {

			if _, exists := uniqueNames[file.Name()]; !exists {
				names = append(names, file.Name())
				uniqueNames[file.Name()] = struct{}{}
			}
		}
	}

	accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))
	re := regexp.MustCompile("^[a-z0-9]+$")
	form := huh.NewForm(
		huh.NewGroup(huh.NewNote().
			Title("Cluster Forge").
			Description("TO THE FORGE!\n\nLets get started")),
		huh.NewGroup(huh.NewText().
			Title("Name of this composition package").
			CharLimit(25).
			Validate(func(input string) error {
				if !re.MatchString(input) {
					return fmt.Errorf("input can only contain lowercase letters (a-z) and digits (0-9)")
				}
				return nil
			}).
			Value(&castname)),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Options(huh.NewOptions(names...)...).
				Title("Choose your target tools to setup").
				Description("Which tools are we working with now?.").
				Validate(func(t []string) error {
					if len(t) <= 0 {
						return fmt.Errorf("at least one tool is required")
					}
					return nil
				}).
				Value(&toolbox.Targettool.Type).
				Filterable(true),
		),
	).WithAccessible(accessible)

	err = form.Run()

	if err != nil {
		log.Fatal("Uh oh:", err)
	}
	filesDir := "./output"
	//remove 'all' from the toolbox.Targettool.Type array
	names = removeElement(names, "all")
	secretFiles := []string{}
	prepareTool := func() {
		configMap := make(map[string]utils.Config)

		for _, config := range configs {
			configMap[config.Name] = config
		}

		for _, tool := range names {
			if config, exists := configMap[tool]; exists {
				utils.CreateCrossplaneObject(config)
				utils.RemoveEmptyYAMLFiles("output")
				// fetch all files with the selected names
				crdFile, secretFile, externalSecretFile, objectFile, err := FetchFilesAndCategorize(filesDir, tool)
				if err != nil {
					log.Error("Error:", err)
					return
				}

				// Retrieve the struct, modify it, and put it back into the map
				config.CRDFiles = append(config.CRDFiles, crdFile...)
				config.ExternalSecretFiles = append(config.ExternalSecretFiles, externalSecretFile...)
				config.SecretFiles = append(config.SecretFiles, secretFile...)
				config.ObjectFiles = append(config.ObjectFiles, objectFile...)

				configMap[tool] = config

				secretFiles = append(secretFiles, secretFile...)
			}
		}
		if len(secretFiles) != 0 {
			rawsecrets := false
			form := huh.NewForm(
				huh.NewGroup(
					huh.NewConfirm().
						Title("You have secrets which are not converted to ExternalSecrets.\nAre you sure you want to continue?").
						Value(&rawsecrets)))
			err = form.Run()
			if err != nil {
				log.Fatal("Uh oh:", err)
			}
			if !rawsecrets {
				log.Fatal("Fix secrets and try again...")
			}
		}
		for _, tool := range names {
			if config, exists := configMap[tool]; exists {
				config.CastName = castname
				if len(config.CRDFiles) != 0 {
					var crdFilesContent []string
					for _, file := range config.CRDFiles {
						filePath := filepath.Join("output", file)
						content, err := os.ReadFile(filePath)
						if err != nil {
							log.Fatal("Error reading file:", err)
						}
						crdFilesContent = append(crdFilesContent, string(content))
					}
					crdFilesStr := strings.Join(crdFilesContent, "\n---\n") // Use "---" to separate YAML documents
					utils.CreatePackage(config, "crds", crdFilesStr)
				}
				if len(config.ObjectFiles) != 0 {
					var objectFilesContent []string
					for _, file := range config.ObjectFiles {
						filePath := filepath.Join("output", file)
						content, err := os.ReadFile(filePath)
						if err != nil {
							log.Fatal("Error reading file:", err)
						}
						objectFilesContent = append(objectFilesContent, string(content))
					}
					objectFilesStr := strings.Join(objectFilesContent, "\n---\n") // Use "---" to separate YAML documents
					utils.CreatePackage(config, "objects", objectFilesStr)
				}

				if len(config.SecretFiles) != 0 || len(config.ExternalSecretFiles) != 0 {
					var secretFilesContent []string
					if len(config.SecretFiles) != 0 {
						for _, file := range config.SecretFiles {
							filePath := filepath.Join("output", file)
							content, err := os.ReadFile(filePath)
							if err != nil {
								log.Fatal("Error reading file:", err)
							}
							secretFilesContent = append(secretFilesContent, string(content))
						}
					}
					if len(config.ExternalSecretFiles) != 0 {
						for _, file := range config.ExternalSecretFiles {
							filePath := filepath.Join("output", file)
							content, err := os.ReadFile(filePath)
							if err != nil {
								log.Fatal("Error reading file:", err)
							}
							secretFilesContent = append(secretFilesContent, string(content))
						}
					}
					secretFilesStr := strings.Join(secretFilesContent, "\n---\n") // Use "---" to separate YAML documents
					utils.CreatePackage(config, "secrets", secretFilesStr)
				}
			}

		}
	}

	_ = spinner.New().Title("Preparing your tools...").Accessible(accessible).Action(prepareTool).Run()

	// Print toolbox summary.

	{
		var sb strings.Builder
		keyword := func(s string) string {
			return lipgloss.NewStyle().Foreground(lipgloss.Color("212")).Render(s)
		}
		fmt.Fprintf(&sb,
			"%s\n\nCompleted: %s.",
			lipgloss.NewStyle().Bold(true).Render("Cluster Forge"),
			keyword(xstrings.EnglishJoin(toolbox.Targettool.Type, true)),
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
}
