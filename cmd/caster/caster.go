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
	err = utils.RemoveYAMLFiles("output")
	if err != nil {
		log.Fatalf("failed to remove YAML files: %s", err)
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
	if toolbox.Targettool.Type[0] == "all" {
		toolbox.Targettool.Type = append(toolbox.Targettool.Type, names...)
	}
	//remove 'all' from the toolbox.Targettool.Type array
	toolbox.Targettool.Type = removeElement(toolbox.Targettool.Type, "all")
	secretFiles := []string{}
	prepareTool := func() {
		configMap := make(map[string]utils.Config)

		for _, config := range configs {
			configMap[config.Name] = config
		}

		for _, tool := range toolbox.Targettool.Type {
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
	}

	_ = spinner.New().Title("Preparing your tools...").Accessible(accessible).Action(prepareTool).Run()
	utils.GenerateFunctionTemplates("output", "output/function-templates.yaml")
	err = utils.CopyYAMLFiles("cmd/utils/templates", "output")
	utils.CopyFile("cmd/utils/templates/deploy.sh", "output/deploy.sh")
	if err != nil {
		log.Fatalf("failed to copy YAML files: %s", err)
	}
	// TODO Need to handle namespaces better. Ignore default, and don't have duplicates. Also, create these first, along with CRDs in forge step
	// Create the subdirectory in /stacks with the name of castname
	packageDir := filepath.Join("stacks", castname)
	err = os.MkdirAll(packageDir, 0755)
	if err != nil {
		log.Fatalf("failed to create package directory: %s", err)
	}
	// Move files from /output to the new subdirectory
	outputDir = "output"
	files, err = os.ReadDir(outputDir)
	if err != nil {
		log.Fatalf("failed to read output directory: %s", err)
	}

	for _, file := range files {
		if !file.IsDir() && !strings.HasPrefix(file.Name(), ".") {
			srcPath := filepath.Join(outputDir, file.Name())
			dstPath := filepath.Join(packageDir, file.Name())
			err = utils.CopyFile(srcPath, dstPath)
			if err != nil {
				log.Fatalf("failed to move file %s: %s", file.Name(), err)
			}
		}
	}
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
