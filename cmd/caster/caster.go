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
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	"github.com/google/uuid"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

type toolbox struct {
	Targettool targettool
}

type targettool struct {
	Type []string
}

func Cast(configs []utils.Config, filesDir string, workingDir string, stacksDir string, publishImage bool) {
	log.Info("Starting up the menu...")

	castname, _, toolTypes := handleInteractiveForm(workingDir, publishImage)

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

	displaySuccessMessage(castname)
}

func handleInteractiveForm(workingDir string, publishImage bool) (string, string, []string) {
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
	var imagename string
	var toolTypes []string
	domainRe := regexp.MustCompile(`^(?:[a-zA-Z0-9.-]+)(?:/[a-zA-Z0-9-_]+)*(?::[a-zA-Z0-9._-]+)?$`)
	re := regexp.MustCompile("^[a-z0-9_-]+$")

	if !publishImage {
		// Set default image name
		imagename = "ttl.sh/" + strings.ToLower(uuid.New().String()) + ":12h"
	}

	form := []*huh.Group{
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
	}

	if publishImage {
		form = append(form, huh.NewGroup(huh.NewText().
			Title("Container Registry and Package name (URL of the registry entry, i.e. ghcr.io/silogen/clusterforge)").
			CharLimit(65).
			Validate(func(input string) error {
				if !domainRe.MatchString(input) {
					return fmt.Errorf("input must be a valid URL domain and tag")
				}
				return nil
			}).
			Value(&imagename)))
	}

	form = append(form, huh.NewGroup(
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
	))

	if err := huh.NewForm(form...).Run(); err != nil {
		log.Fatalf("Interactive form failed: %v", err)
	}

	// Handle "all" selection

	return castname, imagename, toolTypes
}

func CastTool(configs []utils.Config, toolTypes []string, filesDir, workingDir string) error {
	// Initialize the configuration map

	return nil
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

func BuildAndPushImage(imageName string) error {
	cmd := exec.Command("docker", "buildx", "build", "-t", imageName, "--platform", "linux/amd64,linux/arm64", "-f", "docker_forge", "--push", ".")

	// Capture stdout and stderr
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to get stdout pipe: %w", err)
	}

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("failed to get stderr pipe: %w", err)
	}

	// Buffers to capture stderr and stdout for later inspection
	var stderrBuffer bytes.Buffer
	var stdoutBuffer bytes.Buffer

	// Log stdout in a goroutine
	go func() {
		_, err := io.Copy(io.MultiWriter(log.WithField("stream", "stdout").WriterLevel(log.DebugLevel), &stdoutBuffer), stdoutPipe)
		if err != nil {
			log.Errorf("error capturing stdout: %v", err)
		}
	}()

	// Log stderr in a goroutine
	go func() {
		_, err := io.Copy(io.MultiWriter(log.WithField("stream", "stderr").WriterLevel(log.InfoLevel), &stderrBuffer), stderrPipe)
		if err != nil {
			log.Errorf("error capturing stderr: %v", err)
		}
	}()

	// Run the command
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to build and push image: %w", err)
	}

	return nil
}
