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

func Cast(filesDir string, stacksDir string, publishImage bool, imageName string, stackName string, persistentGitea bool, nonInteractive bool) string {

	log.Info("Starting up the menu...")

	if nonInteractive {
		if err := CastTool(filesDir, imageName, publishImage, stackName, persistentGitea); err != nil {
			log.Fatalf("Error during preparation: %v", err)
		}
	} else {
		if imageName == "" || stackName == "" {
			stackName, imageName = handleInteractiveForm(publishImage)
		}

		accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))
		err := spinner.New().
			Title("Preparing your stack...").
			Accessible(accessible).
			Action(func() {
				if err := CastTool(filesDir, imageName, publishImage, stackName, persistentGitea); err != nil {
					log.Fatalf("Error during preparation: %v", err)
				}
			}).
			Run()
		if err != nil {
			log.Fatalf("Error during preparation: %v", err)
		}
	}

	if nonInteractive {
		log.Println("Completed stack: " + stackName + " image: " + imageName)
	} else {
		displaySuccessMessage(stackName, imageName)
	}
	return stackName
}

func handleInteractiveForm(publishImage bool) (string, string) {
	var stackName string
	var imageName string
	domainRe := regexp.MustCompile(`^(?:[a-zA-Z0-9.-]+)(?:/[a-zA-Z0-9-_]+)*(?::[a-zA-Z0-9._-]+)?$`)
	re := regexp.MustCompile("^[a-z0-9_-]+$")

	if !publishImage {
		imageName = "ttl.sh/" + strings.ToLower(uuid.New().String()) + ":12h"
		stackName = "ephemeral-stack"
	}
	if publishImage {
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
				Value(&stackName)),
		}

		form = append(form, huh.NewGroup(huh.NewText().
			Title("Container Registry and Package name (URL of the registry entry, i.e. ghcr.io/silogen/clusterforge)").
			CharLimit(65).
			Validate(func(input string) error {
				if !domainRe.MatchString(input) {
					return fmt.Errorf("input must be a valid URL domain and tag")
				}
				return nil
			}).
			Value(&imageName)))

		if err := huh.NewForm(form...).Run(); err != nil {
			log.Fatalf("Interactive form failed: %v", err)
		}
	}

	return stackName, imageName
}

func CastTool(filesDir, imageName string, publishImage bool, stackName string, persistentGitea bool) error {
	tempDir, err := os.MkdirTemp("", "forger")
	if err != nil {
		log.Error("Failed to create temporary directory: %v\n", err)
		return err
	}
	defer func() {
		if err := os.RemoveAll(tempDir); err != nil {
			log.Error("Failed to remove temporary directory: %v\n", err)
		}
	}()
	utils.CopyDir("cmd/utils/templates/data", tempDir, false)
	os.RemoveAll(tempDir + "/git/gitea-repositories/forge/clusterforge.git")
	os.MkdirAll(tempDir+"/git/gitea-repositories/forge/clusterforge.git", 0755)
	utils.CopyDir(filesDir+"/.git", tempDir+"/git/gitea-repositories/forge/clusterforge.git", false)
	utils.CopyDir(tempDir, "stacks/latest", false)
	BuildAndPushImage(imageName)
	os.RemoveAll("stacks/latest")
	utils.CopyDir(filesDir, "stacks/latest", false)
	utils.CopyFile("cmd/utils/templates/argoapp.yaml", "stacks/latest/argoapp.yaml")
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_URL", imageName)
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_BRANCH", imageName)
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_PATH_PREFIX", imageName)
	utils.CopyFile("cmd/utils/templates/argocd.yaml", "stacks/latest/argocd.yaml")
	if persistentGitea {
		utils.CopyFile("cmd/utils/templates/gitea_pvc.yaml", "stacks/latest/gitea.yaml")
	} else {
		utils.CopyFile("cmd/utils/templates/gitea.yaml", "stacks/latest/gitea.yaml")
	}
	utils.ReplaceStringInFile("stacks/latest/gitea.yaml", "GENERATED_IMAGE", imageName)
	utils.CopyFile("cmd/utils/templates/deploy.sh", "stacks/latest/deploy.sh")
	if publishImage {
		utils.CopyDir("stacks/latest", "stacks/"+stackName, false)
	}
	return nil
}

func displaySuccessMessage(stackName string, imageName string) {
	var sb strings.Builder
	fmt.Fprintf(&sb,
		"%s\n\nCompleted stack: %s\n\nStack image: %s\n",
		lipgloss.NewStyle().Bold(true).Render("Cluster Forge"),
		stackName, imageName,
	)
	fmt.Println(
		lipgloss.NewStyle().
			Width(80).
			BorderStyle(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("63")).
			Padding(1, 1).
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
		log.Fatalf("failed to build and push image: %v", err)
		os.Exit(1)
	}
	// Verify, that image exists in registry
	checkCmd := exec.Command("docker", "manifest", "inspect", imageName)
	if err := checkCmd.Run(); err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			log.Fatalf("Build failed, image %s not found in registry: ", imageName)
			os.Exit(1)
		}
	}
	return nil
}
