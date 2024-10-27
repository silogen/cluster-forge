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
	"io/ioutil"
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
		content, err := ioutil.ReadFile(filePath)
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
	outputDir := "./output"

	// List all files in the output directory
	files, err := os.ReadDir(outputDir)
	if err != nil {
		log.Error("Failed to read directory: %v\n", err)
		return
	}

	// Filter all .yaml files and ensure names are unique
	uniqueNames := make(map[string]struct{})
	castname := ""
	for _, file := range files {
		if !file.IsDir() && filepath.Ext(file.Name()) == ".yaml" {
			baseName := strings.SplitN(file.Name(), "-", 2)[0]
			if _, exists := uniqueNames[baseName]; !exists {
				names = append(names, baseName)
				uniqueNames[baseName] = struct{}{}
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
	var combinedObjects string
	var combinedCRDs string
	var combinedExternalSecrets string
	//remove 'all' from the toolbox.Targettool.Type array
	names = removeElement(names, "all")
	crdFiles := []string{}
	secretFiles := []string{}
	externalSecretFiles := []string{}
	objectFiles := []string{}
	prepareTool := func() {
		for _, tool := range names {
			// fetch all files with the selected names
			crdFile, secretFile, externalSecretFile, objectFile, err := FetchFilesAndCategorize(filesDir, tool)
			if err != nil {
				log.Error("Error:", err)
				return
			}

			crdFiles = append(crdFiles, crdFile...)
			secretFiles = append(secretFiles, secretFile...)
			externalSecretFiles = append(externalSecretFiles, externalSecretFile...)
			objectFiles = append(objectFiles, objectFile...)

		}
		for _, extSecretFile := range externalSecretFiles {
			extSecretPrefix := strings.SplitN(extSecretFile, "-", 2)[0]
			for i := 0; i < len(secretFiles); i++ {
				secretPrefix := strings.SplitN(secretFiles[i], "-", 2)[0]
				if secretPrefix == extSecretPrefix {
					// Remove the element from secretFiles
					secretFiles = append(secretFiles[:i], secretFiles[i+1:]...)
					i-- // Adjust index after removal
				}
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
			combinedObjects = combineFiles(secretFiles, filesDir)

		}
		if len(crdFiles) != 0 {
			combinedCRDs += combineFiles(crdFiles, filesDir)
		}
		if len(externalSecretFiles) != 0 {
			combinedExternalSecrets += combineFiles(externalSecretFiles, filesDir)
		}
		combinedObjects += combineFiles(objectFiles, filesDir)
		utils.CreatePackage(castname+"-externalsecrets", combinedExternalSecrets)
		utils.CreatePackage(castname+"-crds", combinedCRDs)
		utils.CreatePackage(castname+"-objects", combinedObjects)
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
