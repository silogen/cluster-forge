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
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/google/uuid"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

func Cast(filesDir string, stacksDir string, publishImage bool, imageName string, stackName string, gitea utils.GiteaParameters, nonInteractive bool, gitops utils.GitopsParameters, argocdui bool) string {

	log.Info("Starting up the menu...")

	stackName, imageName = handleInteractiveForm(publishImage, imageName, stackName)

	if nonInteractive {
		if err := CastTool(filesDir, imageName, publishImage, stackName, gitea, gitops, argocdui); err != nil {
			log.Fatalf("Error during preparation: %v", err)
		}
	} else {
		accessible, _ := strconv.ParseBool(os.Getenv("ACCESSIBLE"))
		err := spinner.New().
			Title("Preparing your stack...").
			Accessible(accessible).
			Action(func() {
				if err := CastTool(filesDir, imageName, publishImage, stackName, gitea, gitops, argocdui); err != nil {
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

func handleInteractiveForm(publishImage bool, imageName string, stackName string) (string, string) {
	domainRe := regexp.MustCompile(`^(?:[a-zA-Z0-9.-]+)(?:/[a-zA-Z0-9-_]+)*(?::[a-zA-Z0-9._-]+)?$`)
	re := regexp.MustCompile("^[a-z0-9_-]+$")

	if imageName != "" && stackName != "" {
		return stackName, imageName
	}

	if !publishImage {
		if imageName == "" {
			imageName = "ttl.sh/" + strings.ToLower(uuid.New().String()) + ":12h"
		}
	} else {
		form := []*huh.Group{}
		if stackName == "" {
			form = append(form, huh.NewGroup(huh.NewText().
				Title("Name of this composition package").
				CharLimit(25).
				Validate(func(input string) error {
					if !re.MatchString(input) {
						return fmt.Errorf("input can only contain lowercase letters (a-z), digits (0-9), hyphens (-), and underscores (_)")
					}
					return nil
				}).
				Value(&stackName)))
		}

		if imageName == "" {
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
		}

		if err := huh.NewForm(form...).Run(); err != nil {
			log.Fatalf("Interactive form failed: %v", err)
		}
	}

	return stackName, imageName
}

func CastTool(filesDir string, imageName string, publishImage bool, stackName string, gitea utils.GiteaParameters, gitops utils.GitopsParameters, argocdui bool) error {
	if gitea.Deploy {
		BuildAndPushImage(imageName, filesDir)
	}
	os.RemoveAll("stacks/latest")
	utils.CopyDir(filesDir, "stacks/latest", false)
	utils.CopyFile("cmd/utils/templates/argoapp.yaml", "stacks/latest/argoapp.yaml")
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_URL", gitops.Url)
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_BRANCH", gitops.Branch)
	utils.ReplaceStringInFile("stacks/latest/argoapp.yaml", "GITOPS_PATH_PREFIX", gitops.PathPrefix)
	utils.CopyFile("cmd/utils/templates/argocd-secret-job.yaml", "stacks/latest/argocd-secret-job.yaml")
	if argocdui {
		utils.CopyFile("cmd/utils/templates/argocd_full.yaml", "stacks/latest/argocd.yaml")
	} else {
		utils.CopyFile("cmd/utils/templates/argocd.yaml", "stacks/latest/argocd.yaml")
		utils.CopyFile("cmd/utils/templates/argocd2.yaml", "stacks/latest/argocd2.yaml")
	}
	if gitea.Persistent {
		utils.CopyFile("cmd/utils/templates/gitea_pvc.yaml", "stacks/latest/gitea.yaml")
	} else if gitea.Deploy {
		utils.CopyFile("cmd/utils/templates/gitea.yaml", "stacks/latest/gitea.yaml")
	}

	if !gitea.Deploy {
		utils.CopyFile("cmd/utils/templates/deploy_no_gitea.sh", "stacks/latest/deploy.sh")
	} else {
		utils.CopyFile("cmd/utils/templates/deploy.sh", "stacks/latest/deploy.sh")
		utils.ReplaceStringInFile("stacks/latest/gitea.yaml", "GENERATED_IMAGE", imageName)
	}

	if publishImage || stackName != "" {
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

func BuildAndPushImage(imageName string, filesDir string) error {
	tempDir, err := os.MkdirTemp("", "forger")
	if err != nil {
		log.Errorf("Failed to create temporary directory: %v\n", err)
		return err
	}
	defer func() {
		if err := os.RemoveAll(tempDir); err != nil {
			log.Errorf("Failed to remove temporary directory: %v\n", err)
		}
	}()
	CreateAndCommitRepo(filesDir, "Cast commit")
	utils.CopyDir("cmd/utils/templates/data", tempDir, false)
	os.RemoveAll(tempDir + "/git/gitea-repositories/forge/clusterforge.git")
	os.MkdirAll(tempDir+"/git/gitea-repositories/forge/clusterforge.git", 0755)
	utils.CopyDir(filesDir+"/.git", tempDir+"/git/gitea-repositories/forge/clusterforge.git", false)
	utils.CopyDir(tempDir, "stacks/latest", false)

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

// CreateAndCommitRepo creates a new Git repository and commits all files and directories from the specified path.
func CreateAndCommitRepo(path string, commitMessage string) error {
	repo, err := git.PlainInit(path, false)
	if err != nil {
		return fmt.Errorf("failed to initialize repository: %v", err)
	}
	worktree, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("failed to get worktree: %v", err)
	}
	err = filepath.Walk(path, func(filePath string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		// Skip the root directory
		if filePath == path {
			return nil
		}

		// Skip .git, .DS_Store, and .gitkeep
		if info.IsDir() && info.Name() == ".git" {
			return filepath.SkipDir
		}
		if info.Name() == ".DS_Store" || info.Name() == ".gitkeep" {
			return nil
		}

		relPath, err := filepath.Rel(path, filePath)
		if err != nil {
			return err
		}

		// If it's a directory, skip it
		if info.IsDir() {
			return nil
		}

		// Add the file to the Git index
		if _, err := worktree.Add(relPath); err != nil {
			return fmt.Errorf("failed to add file to worktree: %v", err)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to walk directory: %v", err)
	}

	// Commit the changes
	_, err = worktree.Commit(commitMessage, &git.CommitOptions{
		Author: &object.Signature{
			Name:  "ClusterForge",
			Email: "cluster@forge.com",
			When:  time.Now(),
		},
	})
	if err != nil {
		return fmt.Errorf("failed to commit changes: %v", err)
	}

	return nil
}
