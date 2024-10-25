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
	"fmt"
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
		fmt.Println("Uh oh:", err)
		os.Exit(1)
	}
	if toolbox.Targettool.Type[0] == "all" {
		for _, config := range configs {
			toolbox.Targettool.Type = append(toolbox.Targettool.Type, config.Name)
		}
	}

	prepareTool := func() {
		for _, tool := range toolbox.Targettool.Type {
			for _, config := range configs {
				if config.Name == tool {
					log.Debug("running setup for ", config.Name)
					config.Filename = "working/pre/" + config.Name + ".yaml"
					files, _ := os.ReadDir("working/pre/" + config.Name)
					for _, file := range files {
						if !file.IsDir() && !strings.Contains(file.Name(), "ExternalSecret") {
							err := os.Remove("working/" + config.Name + "/" + file.Name())
							if err != nil {
								fmt.Println("Error deleting file:", err)
							}
						}
					}
					utils.Templatehelm(config)
					SplitYAML(config)
					utils.CreateCrossplaneObject(config)

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
