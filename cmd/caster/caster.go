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

func Cast(filesDir string, stacksDir string, publishImage bool) string {

	log.Info("Starting up the menu...")

	stackname, imagename := handleInteractiveForm(publishImage)

	accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))
	err := spinner.New().
		Title("Preparing your stack...").
		Accessible(accessible).
		Action(func() {
			if err := CastTool(filesDir, imagename, publishImage, stackname); err != nil {
				log.Fatalf("Error during preparation: %v", err)
			}
		}).
		Run()
	if err != nil {
		log.Fatalf("Error during preparation: %v", err)
	}

	displaySuccessMessage(stackname, imagename)
	return stackname
}

func handleInteractiveForm(publishImage bool) (string, string) {
	var stackname string
	var imagename string
	domainRe := regexp.MustCompile(`^(?:[a-zA-Z0-9.-]+)(?:/[a-zA-Z0-9-_]+)*(?::[a-zA-Z0-9._-]+)?$`)
	re := regexp.MustCompile("^[a-z0-9_-]+$")

	if !publishImage {
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
			Value(&stackname)),
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

	if err := huh.NewForm(form...).Run(); err != nil {
		log.Fatalf("Interactive form failed: %v", err)
	}

	return stackname, imagename
}

func CastTool(filesDir, imagename string, publishImage bool, stackname string) error {
	tempDir, err := os.MkdirTemp("", "forger")
	if err != nil {
		fmt.Printf("Failed to create temporary directory: %v\n", err)
		return err
	}
	defer func() {
		if err := os.RemoveAll(tempDir); err != nil {
			fmt.Printf("Failed to remove temporary directory: %v\n", err)
		}
	}()
	utils.CopyDir("cmd/utils/templates/data", tempDir)
	os.RemoveAll(tempDir + "/git/gitea-repositories/forge/clusterforge.git")
	os.MkdirAll(tempDir+"/git/gitea-repositories/forge/clusterforge.git", 0755)
	utils.CopyDir(filesDir+"/.git", tempDir+"/git/gitea-repositories/forge/clusterforge.git")
	utils.CopyDir(tempDir, "stacks/latest")
	if publishImage {
		utils.CopyDir("stacks/latest", "stacks/"+stackname)
	}
	BuildAndPushImage(imagename)

	return nil
}

func displaySuccessMessage(stackname string, imagename string) {
	var sb strings.Builder
	fmt.Fprintf(&sb,
		"%s\n\nCompleted stack: %s.\nStack image: %s\n",
		lipgloss.NewStyle().Bold(true).Render("Cluster Forge"),
		stackname, imagename,
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
	cmd := exec.Command("docker", "buildx", "build", "-t", imageName, "--platform", "linux/amd64,linux/arm64", "-f", "Dockerfile", "--push", ".")

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
