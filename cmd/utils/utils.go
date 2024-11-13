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

package utils

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	log "github.com/sirupsen/logrus"
	"golang.org/x/term"
	"gopkg.in/yaml.v2"
)

// ClusterScopedResource represents a Kubernetes cluster-scoped resource.
type ClusterScopedResource struct {
	Name       string
	APIVersion string
}

// clusterScopedResources holds a list of known cluster-scoped resources.
var clusterScopedResources = []ClusterScopedResource{
	{"ComponentStatus", "v1"},
	{"Namespace", "v1"},
	{"Node", "v1"},
	{"PersistentVolume", "v1"},
	{"MutatingWebhookConfiguration", "admissionregistration.k8s.io/v1"},
	{"ValidatingWebhookConfiguration", "admissionregistration.k8s.io/v1"},
	{"CustomResourceDefinition", "apiextensions.k8s.io/v1"},
	{"APIService", "apiregistration.k8s.io/v1"},
	{"ClusterComplianceReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterConfigAuditReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterInfraAssessmentReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterRbacAssessmentReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterSbomReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterVulnerabilityReport", "aquasecurity.github.io/v1alpha1"},
	{"ClusterWorkflowTemplate", "argoproj.io/v1alpha1"},
	{"SelfSubjectReview", "authentication.k8s.io/v1"},
	{"TokenReview", "authentication.k8s.io/v1"},
	{"SelfSubjectAccessReview", "authorization.k8s.io/v1"},
	{"SelfSubjectRulesReview", "authorization.k8s.io/v1"},
	{"SubjectAccessReview", "authorization.k8s.io/v1"},
	{"AllowlistedV2Workload", "auto.gke.io/v1"},
	{"AllowlistedWorkload", "auto.gke.io/v1"},
	{"ClusterIssuer", "cert-manager.io/v1"},
	{"CertificateSigningRequest", "certificates.k8s.io/v1"},
	{"CiliumEndpointSlice", "cilium.io/v2alpha1"},
	{"CiliumExternalWorkload", "cilium.io/v2"},
	{"CiliumIdentity", "cilium.io/v2"},
	{"CiliumNode", "cilium.io/v2"},
	{"ClusterExternalSecret", "external-secrets.io/v1beta1"},
	{"ClusterSecretStore", "external-secrets.io/v1beta1"},
	{"FlowSchema", "flowcontrol.apiserver.k8s.io/v1"},
	{"PriorityLevelConfiguration", "flowcontrol.apiserver.k8s.io/v1"},
	{"Membership", "hub.gke.io/v1"},
	{"ClusterAdmissionReport", "kyverno.io/v1alpha2"},
	{"ClusterBackgroundScanReport", "kyverno.io/v1alpha2"},
	{"ClusterCleanupPolicy", "kyverno.io/v2beta1"},
	{"ClusterPolicy", "kyverno.io/v1"},
	{"NodeMetrics", "metrics.k8s.io/v1beta1"},
	{"ClusterNodeMonitoring", "monitoring.googleapis.com/v1"},
	{"ClusterPodMonitoring", "monitoring.googleapis.com/v1"},
	{"ClusterRules", "monitoring.googleapis.com/v1"},
	{"GlobalRules", "monitoring.googleapis.com/v1"},
	{"DataplaneV2Encryption", "networking.gke.io/v1alpha1"},
	{"GKENetworkParamSet", "networking.gke.io/v1"},
	{"NetworkLogging", "networking.gke.io/v1alpha1"},
	{"Network", "networking.gke.io/v1"},
	{"RemoteNode", "networking.gke.io/v1alpha1"},
	{"ClusterDomainClaim", "networking.internal.knative.dev/v1alpha1"},
	{"IngressClass", "networking.k8s.io/v1"},
	{"RuntimeClass", "node.k8s.io/v1"},
	{"ClusterRoleBinding", "rbac.authorization.k8s.io/v1"},
	{"ClusterRole", "rbac.authorization.k8s.io/v1"},
	{"PriorityClass", "scheduling.k8s.io/v1"},
	{"VolumeSnapshotClass", "snapshot.storage.k8s.io/v1"},
	{"VolumeSnapshotContent", "snapshot.storage.k8s.io/v1"},
	{"CSIDriver", "storage.k8s.io/v1"},
	{"CSINode", "storage.k8s.io/v1"},
	{"StorageClass", "storage.k8s.io/v1"},
	{"VolumeAttachment", "storage.k8s.io/v1"},
	{"Connector", "tailscale.com/v1alpha1"},
	{"ProxyClass", "tailscale.com/v1alpha1"},
	{"Audit", "warden.gke.io/v1"},
}

// LoadConfig loads the configuration file
func LoadConfig(filename string) ([]Config, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	var configs []Config
	err = yaml.Unmarshal(data, &configs)
	if err != nil {
		return nil, err
	}
	err = validateConfig(configs)
	if err != nil {
		return nil, err
	}
	return configs, nil
}

// Config is the struct for the an individual tool config
type Config struct {
	HelmChartName       string `yaml:"helm-chart-name"`
	HelmURL             string `yaml:"helm-url"`
	Values              string `yaml:"values"`
	Secrets             bool   `yaml:"secrets"`
	Name                string `yaml:"name"`
	HelmName            string `yaml:"helm-name"`
	ManifestURL         string `yaml:"manifest-url"`
	HelmVersion         string `yaml:"helm-version"`
	Namespace           string `yaml:"namespace"`
	SourceFile          string `yaml:"sourcefile"`
	Filename            string
	CRDFiles            []string
	SecretFiles         []string
	ExternalSecretFiles []string
	ObjectFiles         []string
	CastName            string
}

// Setup sets up the logging
func Setup() {
	// Get the log level from the environment variable
	logLevelStr := os.Getenv("LOG_LEVEL")
	if logLevelStr == "" {
		logLevelStr = "DEFAULT"
	}
	logLevel, err := log.ParseLevel(logLevelStr)
	if err != nil {
		logLevel = log.InfoLevel
	}

	// Set the log level
	log.SetLevel(logLevel)

	// Set the output destination to a file
	logfilename := os.Getenv("LOG_NAME")
	if logfilename == "" {
		logfilename = "app.log"
	}
	logfilename = "logs/" + logfilename
	file, err := os.OpenFile(logfilename, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Fatal(err)
	}
	log.SetOutput(file)
}

// Templatehelm is a funciton to template from the helm values and chart
func Templatehelm(config Config) {
	if config.Name != "" {
		log.Debug("templating helm for ", config.Name)
	}
	if config.HelmURL != "" {
		log.Debug("   Using: ", config.HelmURL)
	}
	if config.HelmChartName != "" {
		log.Debug("   Using: ", config.HelmChartName)
	}
	if config.Values != "" {
		log.Debug("   Using: ", config.Values)
	}
	if config.Filename != "" {
		log.Debug("   Using: ", config.Filename)
	}
	if config.ManifestURL != "" {
		log.Debug("   Using: ", config.ManifestURL)
	}

	file, err := os.Create(config.Filename)
	if err != nil {
		log.Fatal(err)
	}
	defer file.Close()

	if config.HelmURL != "" {
		var cmd *exec.Cmd
		switch {
		case config.HelmVersion != "" && config.Namespace != "":
			// Both HelmVersion and Namespace are provided
			cmd = exec.Command("helm", "template", config.HelmName, "--repo", config.HelmURL, "--version", config.HelmVersion, config.HelmChartName, "--namespace", config.Namespace, "-f", "input/"+config.Name+"/"+config.Values)

		case config.HelmVersion != "":
			// Only HelmVersion is provided
			cmd = exec.Command("helm", "template", config.HelmName, "--repo", config.HelmURL, "--version", config.HelmVersion, config.HelmChartName, "-f", "input/"+config.Name+"/"+config.Values)

		case config.Namespace != "":
			// Only Namespace is provided
			cmd = exec.Command("helm", "template", config.HelmName, "--repo", config.HelmURL, config.HelmChartName, "--namespace", config.Namespace, "-f", "input/"+config.Name+"/"+config.Values)

		default:
			// Neither HelmVersion nor Namespace is provided
			cmd = exec.Command("helm", "template", config.HelmName, "--repo", config.HelmURL, config.HelmChartName, "-f", "input/"+config.Name+"/"+config.Values)
		}
		cmd.Env = append(cmd.Env, "KUBECONFIG=''")
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		cmd.Stdout = file
		err = cmd.Run()
		if err != nil {
			if exitError, ok := err.(*exec.ExitError); ok {
				log.Fatalf("Command exited with error code %d and stderr: %s", exitError.ExitCode(), stderr.String())
			} else {
				log.Fatal(err)
			}
		}
	} else if config.SourceFile != "" {
		log.Debugf("Using " + config.SourceFile)
		// Construct the source and destination file paths
		inputDir := "input"
		workingDir := "working/pre"
		srcFilePath := filepath.Join(inputDir, config.SourceFile)
		dstFilePath := filepath.Join(workingDir, config.SourceFile)

		// Copy the file from input directory to working directory
		err := CopyFile(srcFilePath, dstFilePath)
		config.Filename = config.SourceFile
		if err != nil {
			log.Fatalf("Failed to copy file: %s", err)
		}
	} else if config.ManifestURL != "" {
		log.Debugf("looking for " + config.ManifestURL)
		err := downloadFile(config.Filename, config.ManifestURL)
		if err != nil {
			log.Fatal(err)
		}
	}
}

// Function to copy a file from source to destination
func CopyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	// Ensure the destination directory exists
	dstDir := filepath.Dir(dst)
	err = os.MkdirAll(dstDir, 0755)
	if err != nil {
		return err
	}

	destinationFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destinationFile.Close()

	_, err = io.Copy(destinationFile, sourceFile)
	return err
}
func downloadFile(filepath string, url string) error {

	// Get the data
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Create the file
	out, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer out.Close()

	// Write the body to file
	_, err = io.Copy(out, resp.Body)
	return err
}

// RemoveEmptyYAMLFiles removes empty .yaml files in the specified directory
func RemoveEmptyYAMLFiles(dir string) error {
	files, err := os.ReadDir(dir)
	if err != nil {
		return err
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) == ".yaml" {
			filePath := filepath.Join(dir, file.Name())
			info, err := os.Stat(filePath)
			if err != nil {
				return err
			}
			if info.Size() == 0 {
				err = os.Remove(filePath)
				if err != nil {
					return err
				}
				log.Printf("Removed empty file: %s\n", filePath)
			}
		}
	}
	return nil
}

func ResetTerminal() {
	// Restores terminal state
	if term.IsTerminal(int(os.Stdin.Fd())) {
		_, err := term.MakeRaw(int(os.Stdin.Fd())) // Put terminal in raw mode
		if err != nil {
			log.Errorf("Failed to make terminal raw: %v\n", err)
		}
	}
}

// Function to validate the configuration
func validateConfig(configs []Config) error {
	for _, config := range configs {
		if config.Name == "" {
			return fmt.Errorf("missing 'name' in config: %+v", config)
		}
		if config.Namespace == "" {
			return fmt.Errorf("missing 'namespace' in config: %+v", config)
		}
		if config.ManifestURL == "" && config.HelmURL == "" && config.SourceFile == "" {
			return fmt.Errorf("either 'manifest-url' or 'helm-url' must be provided in config: %+v", config)
		}
		if config.HelmURL != "" {
			if config.HelmChartName == "" {
				return fmt.Errorf("missing 'helm-chart-name' in config with 'helm-url': %+v", config)
			}
			if config.HelmName == "" {
				return fmt.Errorf("missing 'helm-name' in config with 'helm-url': %+v", config)
			}
			if config.Values == "" {
				return fmt.Errorf("missing 'values' in config with 'helm-url': %+v", config)
			}
		}
	}
	return nil
}

// isClusterScoped checks if a given resource is cluster-scoped.
func IsClusterScoped(resourceName, apiVersion string) bool {
	for _, resource := range clusterScopedResources {
		if strings.EqualFold(resource.Name, resourceName) && strings.EqualFold(resource.APIVersion, apiVersion) {
			return true
		}
	}
	return false
}
