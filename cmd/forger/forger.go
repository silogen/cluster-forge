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
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"k8s.io/client-go/util/homedir"
)

func Forge(stacksPath string) {
	log.SetOutput(os.Stdout)
	log.SetFormatter(&log.TextFormatter{
		FullTimestamp: true,
	})
	log.SetLevel(log.DebugLevel)
	log.Info("Starting Cluster Forge...")

	kubeConfigPath := determineKubeConfigPath()
	_, err := getKubeConfig(kubeConfigPath)
	if err != nil {
		log.Fatalf("Failed to configure Kubernetes client: %v", err)
	}

	stacks := getStacks(stacksPath)
	selectedStack := getUserSelection(stacks)

	runStackLogic(filepath.Join(stacksPath, selectedStack))
}

func determineKubeConfigPath() string {
	kubeConfigPath := os.Getenv("KUBECONFIG")
	defaultKubeConfigPath := filepath.Join(homedir.HomeDir(), ".kube", "config")

	if kubeConfigPath != "" {
		log.Infof("KUBECONFIG environment variable detected: %s", kubeConfigPath)

		useEnvKubeconfig := false
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Use KUBECONFIG environment variable").
					Description(fmt.Sprintf("Do you want to use the KUBECONFIG path: %s?", kubeConfigPath)).
					Value(&useEnvKubeconfig),
			),
		)

		if err := form.Run(); err != nil {
			log.Fatalf("Failed to get user input: %v", err)
		}

		if useEnvKubeconfig {
			log.Infof("Using KUBECONFIG environment variable path: %s", kubeConfigPath)
			return kubeConfigPath
		}
	}

	if _, err := os.Stat(defaultKubeConfigPath); os.IsNotExist(err) {
		log.Warnf("Kubeconfig file not found at %s. Falling back to in-cluster configuration.", defaultKubeConfigPath)
		return ""
	}

	log.Infof("Using default kubeconfig path: %s", defaultKubeConfigPath)
	return defaultKubeConfigPath
}

func getKubeConfigPath(defaultPath, kubeconfigEnv string) (string, error) {
	if kubeconfigEnv != "" {
		log.Infof("KUBECONFIG environment variable detected: %s", kubeconfigEnv)

		useEnvKubeconfig := false
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Use KUBECONFIG environment variable").
					Description(fmt.Sprintf("Do you want to use the KUBECONFIG path: %s?", kubeconfigEnv)).
					Value(&useEnvKubeconfig),
			),
		)

		if err := form.Run(); err != nil {
			log.Fatalf("Failed to get user input: %v", err)
		}

		if useEnvKubeconfig {
			return kubeconfigEnv, nil
		}
	}

	if _, err := os.Stat(defaultPath); os.IsNotExist(err) {
		log.Warnf("Kubeconfig file not found at %s. Falling back to in-cluster configuration.", defaultPath)
		return "", nil
	}

	return defaultPath, nil
}

func getKubeConfig(kubeconfigPath string) (*rest.Config, error) {
	if kubeconfigPath == "" {
		return rest.InClusterConfig()
	}

	configLoader := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfigPath},
		&clientcmd.ConfigOverrides{},
	)

	rawConfig, err := configLoader.RawConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to load kubeconfig: %w", err)
	}

	contextName := getUserContextSelection(rawConfig.Contexts)
	configOverrides := &clientcmd.ConfigOverrides{CurrentContext: contextName}
	config := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfigPath},
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
	var stacks []struct {
		name    string
		modTime int64
	}

	files, err := os.ReadDir(baseDir)
	if err != nil {
		log.Fatalf("Failed to read stacks directory: %v", err)
	}

	for _, file := range files {
		if file.IsDir() {
			info, err := file.Info()
			if err != nil {
				log.Fatalf("Failed to get file info for %s: %v", file.Name(), err)
			}
			stacks = append(stacks, struct {
				name    string
				modTime int64
			}{
				name:    file.Name(),
				modTime: info.ModTime().Unix(),
			})
		}
	}

	sort.Slice(stacks, func(i, j int) bool {
		return stacks[i].modTime > stacks[j].modTime
	})

	var result []string
	for _, stack := range stacks {
		result = append(result, stack.name)
	}

	return result
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

	// Helper function to apply YAML files
	applyFile := func(filename string) {
		utils.RunCommand(fmt.Sprintf("kubectl apply -f %s/%s", stackPath, filename))
	}

	// Helper function to wait for a CRD
	waitForCRDWithError := func(crdName string) error {
		if err := waitForCRD(crdName); err != nil {
			log.Errorf("Error waiting for CRD %s: %v", crdName, err)
			return err
		}
		return nil
	}

	// Apply base Crossplane YAML
	applyFile("crossplane_base.yaml")

	// Wait for required CRDs
	requiredCRDs := []string{
		"providers.pkg.crossplane.io",
		"functions.pkg.crossplane.io",
		"deploymentruntimeconfigs.pkg.crossplane.io",
		"compositions.apiextensions.crossplane.io",
		"compositeresourcedefinitions.apiextensions.crossplane.io",
	}

	for _, crd := range requiredCRDs {
		if err := waitForCRDWithError(crd); err != nil {
			return
		}
	}

	// Apply Crossplane and provider YAML files
	applyFile("crossplane.yaml")
	utils.RunCommand("kubectl wait --for=condition=Healthy providers/provider-kubernetes --timeout=60s")
	applyFile("crossplane_provider.yaml")

	// Apply composition and stack YAML files
	applyFile("composition.yaml")

	// Restart Crossplane pods and wait for readiness
	utils.RunCommand("kubectl delete pods --all -n crossplane-system")
	utils.RunCommand("kubectl wait --for=condition=Ready --timeout=600s pods --all -n crossplane-system")

	applyFile("stack.yaml")

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
		utils.RunCommand(command)
	}
}

func installHelmChart(repoName, repoURL, releaseName, chartName string) {
	log.Infof("Installing Helm chart %s from repository %s", chartName, repoURL)
	cmd := fmt.Sprintf(
		"helm repo add %s %s && helm repo update && helm upgrade --install %s %s",
		repoName, repoURL, releaseName, chartName,
	)
	utils.RunCommand(cmd)
}

// waitForCRD waits for a specific CRD to be available and in Established condition
func waitForCRD(crdName string) error {
	fmt.Printf("Waiting for CRD: %s to become available...\n", crdName)

	for {
		// Check if the CRD exists
		if err := exec.Command("kubectl", "get", "crd", crdName).Run(); err != nil {
			fmt.Printf("CRD %s is not found. Retrying in 5 seconds...\n", crdName)
			time.Sleep(5 * time.Second)
			continue
		}

		// Wait for the CRD to reach the Established condition
		cmd := exec.Command("kubectl", "wait", "--for=condition=Established", "crd/"+crdName, "--timeout=60s")
		if output, err := cmd.CombinedOutput(); err != nil {
			fmt.Printf("CRD %s is not ready: %s. Retrying in 5 seconds...\n", crdName, strings.TrimSpace(string(output)))
			time.Sleep(5 * time.Second)
			continue
		}

		// CRD is ready
		fmt.Printf("CRD %s is now ready!\n", crdName)
		break
	}

	return nil
}
