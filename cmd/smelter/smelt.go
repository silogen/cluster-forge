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

package smelter

import (
	"bytes"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	xstrings "github.com/charmbracelet/x/exp/strings"
	log "github.com/sirupsen/logrus"

	"github.com/silogen/cluster-forge/cmd/utils"
)

const namespaceTemplate = `apiVersion: v1
kind: Namespace
metadata:
  name: {{ .NamespaceName }}
`

type toolbox struct {
	Targettool targettool
}

type targettool struct {
	Type []string
}

func Smelt(configs []utils.Config, workingDir string) {
	log.Info("starting up the menu...")
	var targettool targettool
	var toolbox = toolbox{Targettool: targettool}
	var names []string
	names = append(names, "all")
	for _, config := range configs {
		names = append(names, config.Name)
	}
	accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))

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
				Value(&toolbox.Targettool.Type).
				Filterable(true),
		),
	).WithAccessible(accessible)

	err := form.Run()
	if err != nil {
		log.Fatal("Uh oh:", err)
	}
	if toolbox.Targettool.Type[0] == "all" {
		for _, config := range configs {
			toolbox.Targettool.Type = append(toolbox.Targettool.Type, config.Name)
		}
	}

	err = spinner.New().
		Title("Preparing your tools...").
		Accessible(accessible).
		Action(func() {
			if err := PrepareTool(configs, toolbox.Targettool.Type, workingDir); err != nil {
				log.Errorf("Error during tool preparation: %v", err)
			}
		}).
		Run()
	if err != nil {
		log.Fatalf("Tool preparation failed: %v", err)
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

func PrepareTool(configs []utils.Config, targetTools []string, toolBaseDir string) error {
	configMap := make(map[string]utils.Config)

	for _, config := range configs {
		configMap[config.Name] = config
	}

	preDir := filepath.Join(toolBaseDir, "pre")
	if err := os.MkdirAll(preDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", preDir, err)
	}

	for _, tool := range targetTools {
		if config, exists := configMap[tool]; exists {
			namespaceObject := false
			log.Debug("running setup for ", config.Name)
			config.Filename = filepath.Join(preDir, config.Name+".yaml")

			toolDir := filepath.Join(toolBaseDir, config.Name)
			files, _ := os.ReadDir(toolDir)
			for _, file := range files {
				if !file.IsDir() && !strings.Contains(file.Name(), "ExternalSecret") {
					_ = os.Remove(filepath.Join(toolDir, file.Name()))
				}
			}

			utils.Templatehelm(config, &utils.DefaultHelmExecutor{})
			SplitYAML(config, toolBaseDir)

			files, _ = os.ReadDir(toolDir)
			for _, file := range files {
				if !file.IsDir() && strings.Contains(file.Name(), "Namespace") {
					namespaceObject = true
					break
				}
			}

			if !namespaceObject {
				if err := createNamespaceFile(config, toolBaseDir); err != nil {
					return fmt.Errorf("failed to create namespace file: %w", err)
				}
			}
		}
	}

	return nil
}

func createNamespaceFile(config utils.Config, toolBaseDir string) error {
	data := struct {
		NamespaceName string
	}{
		NamespaceName: config.Namespace,
	}

	tmpl, err := template.New("namespace").Parse(namespaceTemplate)
	if err != nil {
		return fmt.Errorf("failed to parse namespace template: %w", err)
	}

	var rendered bytes.Buffer
	if err := tmpl.Execute(&rendered, data); err != nil {
		return fmt.Errorf("failed to execute namespace template: %w", err)
	}

	namespaceDir := filepath.Join(toolBaseDir, config.Name)
	if err := os.MkdirAll(namespaceDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", namespaceDir, err)
	}

	namespaceFilePath := filepath.Join(namespaceDir, "Namespace_"+config.Name+".yaml")
	if err := os.WriteFile(namespaceFilePath, rendered.Bytes(), 0644); err != nil {
		return fmt.Errorf("failed to write namespace file: %w", err)
	}

	return nil
}
