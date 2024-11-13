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

func Smelt(configs []utils.Config) {
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
		huh.NewGroup(huh.NewNote().
			Title("Cluster Forge").
			Description("TO THE FORGE!\n\nLets get started")),

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

	err := form.Run()

	if err != nil {
		log.Fatal("Uh oh:", err)
	}
	if toolbox.Targettool.Type[0] == "all" {
		for _, config := range configs {
			toolbox.Targettool.Type = append(toolbox.Targettool.Type, config.Name)
		}
	}

	prepareTool := func() {
		configMap := make(map[string]utils.Config)

		for _, config := range configs {
			configMap[config.Name] = config
		}

		// Now iterate over the tools and directly access the corresponding config in the map.
		for _, tool := range toolbox.Targettool.Type {
			if config, exists := configMap[tool]; exists {
				namespaceObject := false
				log.Debug("running setup for ", config.Name)
				config.Filename = "working/pre/" + config.Name + ".yaml"
				files, _ := os.ReadDir("working/pre/" + config.Name)
				for _, file := range files {
					if !file.IsDir() && !strings.Contains(file.Name(), "ExternalSecret") {
						err := os.Remove("working/" + config.Name + "/" + file.Name())
						if err != nil {
							log.Error("Error deleting file:", err)
						}
					}
				}
				utils.Templatehelm(config)
				SplitYAML(config)
				files, _ = os.ReadDir("working/" + config.Name)
				for _, file := range files {
					if !file.IsDir() && strings.Contains(file.Name(), "Namespace") {
						namespaceObject = true
					}
				}
				if !namespaceObject && config.SourceFile == "" {
					data := struct {
						NamespaceName string
					}{
						NamespaceName: config.Namespace,
					}
					tmpl, err := template.New("namespace").Parse(namespaceTemplate)
					if err != nil {
						log.Fatal(err)
					}
					var rendered bytes.Buffer
					if err := tmpl.Execute(&rendered, data); err != nil {
						panic(err)
					}
					if err := os.WriteFile("working/"+config.Name+"/Namespace_"+config.Name+".yaml", rendered.Bytes(), 0644); err != nil {
						log.Fatal(err)
					}
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
