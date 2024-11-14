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

package forger

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	log "github.com/sirupsen/logrus"
	"github.com/charmbracelet/huh"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"k8s.io/client-go/util/homedir"
)


func Forge() {
	log.SetOutput(os.Stdout)
	log.SetFormatter(&log.TextFormatter{
		FullTimestamp: true,
	})
	log.SetLevel(log.DebugLevel)
	log.Info("Starting Cluster Forge...")
	base_path := "./packages"
	kubeconfig := filepath.Join(homedir.HomeDir(), ".kube", "config")
	_, err := getKubeConfig(kubeconfig)
	if err != nil {
		log.Fatalf("Failed to configure Kubernetes client: %v", err)
	}

	stacks := getStacks(base_path)
	selectedStack := getUserSelection(stacks)

	runStackLogic(filepath.Join(base_path,selectedStack))
}

func getKubeConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig == "" {
		kubeconfig = filepath.Join(os.Getenv("HOME"), ".kube", "config")
	}

	if _, err := os.Stat(kubeconfig); os.IsNotExist(err) {
		log.Warnf("Kubeconfig file not found at %s. Falling back to in-cluster configuration.", kubeconfig)
		return rest.InClusterConfig()
	}

	configLoader := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfig},
		&clientcmd.ConfigOverrides{},
	)
	rawConfig, err := configLoader.RawConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to load kubeconfig: %w", err)
	}

	contextName := getUserContextSelection(rawConfig.Contexts)
	configOverrides := &clientcmd.ConfigOverrides{CurrentContext: contextName}
	config := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfig},
		configOverrides,
	)

	return config.ClientConfig()
}

func getUserContextSelection(contexts map[string]*clientcmdapi.Context) string {
	var contextNames []string
	for name := range contexts {
		contextNames = append(contextNames, name)
	}

	var selectedContext string
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title("Select a Kubernetes context").
				Description("Choose a context for Kubernetes API interactions.").
				Options(huh.NewOptions(contextNames...)...).
				Value(&selectedContext),
		),
	)

	if err := form.Run(); err != nil {
		log.Fatalf("Failed to get user input: %v", err)
	}
	if selectedContext == "" {
		log.Fatal("No context selected. Exiting.")
	}

	log.Infof("Selected context: %s", selectedContext)
	return selectedContext
}

func getStacks(baseDir string) []string {
	var stacks []string
	files, err := os.ReadDir(baseDir)
	if err != nil {
		log.Fatalf("Failed to read packages directory: %v", err)
	}
	for _, file := range files {
		if file.IsDir() {
			stacks = append(stacks, file.Name())
		}
	}
	return stacks
}

func getUserSelection(stacks []string) string {
	var selectedStack string
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[string]().
				Title("Select a stack to deploy").
				Description("Choose one of the available stacks for deployment.").
				Options(huh.NewOptions(stacks...)...).
				Value(&selectedStack),
		),
	)
	if err := form.Run(); err != nil {
		log.Fatalf("Failed to get user input: %v", err)
	}
	if selectedStack == "" {
		log.Fatal("No stack selected. Exiting.")
	}
	log.Infof("Selected stack: %s", selectedStack)
	return selectedStack
}

func runStackLogic(stackPath string) {
	log.Infof("Deploying stack from: %s", stackPath)

	runCommand(fmt.Sprintf("kubectl apply -f %s/crossplane_base.yaml", stackPath))

	runCommand("kubectl wait --for=condition=available --timeout=600s deployments --all --all-namespaces")

	applyMatchingFiles(stackPath, "crd-*.yaml", true)

	applyMatchingFiles(stackPath, "cm-*.yaml", false)

	runCommand(fmt.Sprintf("kubectl apply -f %s/crossplane.yaml", stackPath))
	time.Sleep(20 * time.Second)
	runCommand(fmt.Sprintf("kubectl apply -f %s/function-templates.yaml", stackPath))
	runCommand(fmt.Sprintf("kubectl apply -f %s/crossplane_provider.yaml", stackPath))
	runCommand(fmt.Sprintf("kubectl apply -f %s/composition.yaml", stackPath))

	runCommand("kubectl delete pods --all -n crossplane-system")
	runCommand("kubectl wait --for=condition=Ready --timeout=600s pods --all --all-namespaces")

	runCommand(fmt.Sprintf("kubectl apply -f %s/claim.yaml", stackPath))
	installHelmChart("komodorio", "https://helm-charts.komodor.io", "komoplane", "komodorio/komoplane")
	runCommand("kubectl wait --for=condition=Ready --timeout=600s pods --all -n default")

	log.Info("Deployment complete!")
}

func applyMatchingFiles(dir string, pattern string, server_side bool) {
	files, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		log.Fatalf("Failed to find files matching pattern %s: %v", pattern, err)
	}

	for _, file := range files {
		command := fmt.Sprintf("kubectl apply -f %s", file)
		if server_side {
			command += " --server-side"
		}
		runCommand(command)
	}
}

func installHelmChart(repoName, repoURL, releaseName, chartName string) {
	log.Infof("Installing Helm chart %s from repository %s", chartName, repoURL)
	cmd := fmt.Sprintf(
		"helm repo add %s %s && helm repo update && helm upgrade --install %s %s",
		repoName, repoURL, releaseName, chartName,
	)
	runCommand(cmd)
}

func runCommand(cmd string) error {
	output, err := exec.Command("sh", "-c", cmd).CombinedOutput()
	if err != nil {
		log.Fatalf("Command %s failed: %v\nOutput: %s", cmd, err, string(output))
	}
	log.Infof(string(output))
	return nil
}

