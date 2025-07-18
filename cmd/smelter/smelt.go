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
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	xstrings "github.com/charmbracelet/x/exp/strings"
	"github.com/silogen/cluster-forge/cmd/utils"
	"github.com/silogen/cluster-forge/cmd/utils/configloader"
	log "github.com/sirupsen/logrus"
)

const namespaceTemplate = `---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .NamespaceName }}
`

func Smelt(configs configloader.ToolSet, workingDir string, nonInteractive bool) {
	log.Info("Smelt starting...")
	tools := slices.Collect(maps.Keys(configs))
	sort.Strings(tools)
	if nonInteractive {
		if err := PrepareTool(configs, workingDir); err != nil {
			log.Fatalf("Error during tool preparation: %v", err)
		}

		log.Println("Completed: " + xstrings.EnglishJoin(tools, true))
	} else {
		accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))

		err := spinner.New().
			Title("Preparing your tools...").
			Accessible(accessible).
			Action(func() {
				if err := PrepareTool(configs, workingDir); err != nil {
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
				keyword(xstrings.EnglishJoin(tools, true)),
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
}

func PrepareTool(configMap configloader.ToolSet, workingDir string) error {

	preDir := filepath.Join(workingDir, "pre")
	if err := os.MkdirAll(preDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", preDir, err)
	}

	for _, config := range configMap {
		if config.SyncWave == "" {
			config.SyncWave = "0"
		}
		namespaceObject := false
		log.Debug("running setup for ", config.Name)
		config.Filename = filepath.Join(preDir, config.Name+".yaml")

		toolDir := filepath.Join(workingDir, config.Name)
		files, _ := os.ReadDir(toolDir)
		for _, file := range files {
			if !file.IsDir() && !strings.Contains(file.Name(), "ExternalSecret") {
				_ = os.Remove(filepath.Join(toolDir, file.Name()))
			}
		}

		err := utils.Templatehelm(config, &utils.DefaultHelmExecutor{})
		if err != nil {
			return fmt.Errorf("failed to parse config: %w", err)
		}
		utils.SplitYAML(config, filepath.Join(workingDir, config.Name))
		utils.CreateApplicationFile(config, filepath.Join(workingDir, "argo-apps"))
		files, _ = os.ReadDir(toolDir)
		for _, file := range files {
			if !file.IsDir() && strings.Contains(file.Name(), "Namespace") {
				namespaceObject = true
				break
			}
		}

		if !namespaceObject && config.Namespace != "default" && config.SkipNamespace != "true" {
			if err = createNamespaceFile(config, workingDir); err != nil {
				return fmt.Errorf("failed to create namespace file: %w", err)
			}
		}
		utils.CleanDescFromResources(toolDir)
	}
	// Replace image tags with SHA values in all YAML files
	if err := utils.ReplaceImageTagsWithSHA(workingDir); err != nil {
		log.Errorf("failed to replace image tags with SHA values: %v", err)
		// Continue execution as this is not a fatal error
	}

	// remove the working/pre directory if not debugging
	if !log.IsLevelEnabled(log.DebugLevel) {
		if err := os.RemoveAll(filepath.Join(workingDir, "pre")); err != nil {
			log.Errorf("failed to remove pre directory: %v", err)
		}
	}

	return nil
}

func createNamespaceFile(config utils.Config, workingDir string) error {
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

	namespaceDir := filepath.Join(workingDir, config.Name)
	if err := os.MkdirAll(namespaceDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", namespaceDir, err)
	}

	namespaceFilePath := filepath.Join(namespaceDir, "Namespace_"+config.Namespace+".yaml")
	if err := os.WriteFile(namespaceFilePath, rendered.Bytes(), 0644); err != nil {
		return fmt.Errorf("failed to write namespace file: %w", err)
	}

	return nil
}
