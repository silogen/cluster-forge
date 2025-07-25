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
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/template"

	log "github.com/sirupsen/logrus"
	"golang.org/x/term"
	"gopkg.in/yaml.v3"
)

type ClusterScopedResource struct {
	Name       string
	APIVersion string
}

var ForgeLogo = "  ____ _           _              _____                    \n" +
	" / ___| |_   _ ___| |_ ___ _ __  |  ___|__  _ __ __ _  ___ \n" +
	"| |   | | | | / __| __/ _ \\ '__| | |_ / _ \\| '__/ _` |/ _ \\\n" +
	"| |___| | |_| \\__ \\ ||  __/ |    |  _| (_) | | | (_| |  __/\n" +
	" \\____|_|\\__,_|___/\\__\\___|_|    |_|  \\___/|_|  \\__, |\\___|\n" +
	"                                                |___/      \n"

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

type GitopsParameters struct {
	Url        string
	Branch     string
	PathPrefix string
}

type Config struct {
	HelmChartName    string   `yaml:"helm-chart-name"`
	HelmURL          string   `yaml:"helm-url"`
	Values           string   `yaml:"values"`
	Name             string   `yaml:"name"`
	HelmName         string   `yaml:"helm-name"`
	ManifestURL      string   `yaml:"manifest-url"`
	HelmVersion      string   `yaml:"helm-version"`
	Namespace        string   `yaml:"namespace"`
	Namespaces       []string `yaml:"namespaces"`
	ManifestPath     []string `yaml:"manifestpath"`
	SyncWave         string   `yaml:"syncwave"`
	Collection       []string `yaml:"collection"`
	SkipNamespace    string   `yaml:"skip-namespace"`
	SourceExclusions []string `yaml:"source-exclusions"`
	Filename         string
	GitopsUrl        string
	GitopsBranch     string
	GitopsPathPrefix string
}

// getPrimaryNamespace returns the primary namespace from config
// If namespaces (plural) is specified, returns the first one
// Otherwise returns the single namespace field (backward compatibility)
func getPrimaryNamespace(config Config) string {
	if len(config.Namespaces) > 0 {
		return config.Namespaces[0]
	}
	return config.Namespace
}

func Setup(nonInteractive bool) {
	logLevelStr := os.Getenv("LOG_LEVEL")
	if logLevelStr == "" {
		logLevelStr = "DEFAULT"
	}
	logLevel, err := log.ParseLevel(logLevelStr)
	if err != nil {
		logLevel = log.InfoLevel
	}

	log.SetLevel(logLevel)

	logfilename := os.Getenv("LOG_NAME")
	if logfilename == "" {
		logfilename = "forge.log"
	}
	logfilename = "logs/" + logfilename
	file, err := os.OpenFile(logfilename, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Fatal(err)
	}
	if nonInteractive {
		log.SetOutput(os.Stdout)
	} else {
		log.SetOutput(file)
	}
}

type HelmExecutor interface {
	RunHelmCommand(args []string, stdout io.Writer, stderr io.Writer) error
}

type DefaultHelmExecutor struct{}

func (e *DefaultHelmExecutor) RunHelmCommand(args []string, stdout io.Writer, stderr io.Writer) error {
	cmd := exec.Command("helm", args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.Env = append(os.Environ(), "KUBECONFIG=''")
	return cmd.Run()
}

func Templatehelm(config Config, helmExec HelmExecutor) error {
	if config.HelmChartName == "" && len(config.ManifestPath) == 0 && config.ManifestURL == "" {
		return fmt.Errorf("invalid configuration: at least one of HelmChartName, ManifestPath, or ManifestURL must be provided")
	}

	primaryNamespace := getPrimaryNamespace(config)
	// Only require namespace for helm charts, since manifest-based tools
	// might already define their own namespaces in the manifests
	if config.HelmChartName != "" && primaryNamespace == "" {
		return fmt.Errorf("invalid configuration: Namespace must not be empty for helm charts")
	}
	file, err := os.Create(config.Filename)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer file.Close()

	if config.HelmChartName != "" {
		valuesPath := fmt.Sprintf("input/%s/default-values.yaml", config.Name)
		fetchValuesArgs := []string{"show", "values", config.HelmChartName}
		if config.HelmURL != "" {
			fetchValuesArgs = append(fetchValuesArgs, "--repo", config.HelmURL)
		}
		if config.HelmVersion != "" {
			fetchValuesArgs = append(fetchValuesArgs, "--version", config.HelmVersion)
		}
		if primaryNamespace != "" {
			fetchValuesArgs = append(fetchValuesArgs, "--namespace", primaryNamespace)
		}
		cmdFetchValues := exec.Command("helm", fetchValuesArgs...)
		output, err := cmdFetchValues.Output()
		if err != nil {
			return fmt.Errorf("failed to fetch default-values.yaml for %s: %+w", config.Name, err)
		}

		err = os.MkdirAll(fmt.Sprintf("input/%s", config.Name), 0755)
		if err != nil {
			return fmt.Errorf("failed to create input directory for %s: %w", config.Name, err)
		}

		err = os.WriteFile(valuesPath, output, 0644)
		if err != nil {
			return fmt.Errorf("failed to write default-values.yaml for %s: %w", config.Name, err)
		}
		if config.Values == "" {
			config.Values = "default-values.yaml"
		}

		args := []string{"template", config.HelmName, config.HelmChartName, "-f", "input/" + config.Name + "/" + config.Values, "--include-crds"}
		if config.HelmURL != "" {
			args = append(args, "--repo", config.HelmURL)
		}
		if config.HelmVersion != "" {
			args = append(args, "--version", config.HelmVersion)
		}
		if primaryNamespace != "" {
			args = append(args, "--namespace", primaryNamespace)
		}

		var stderr bytes.Buffer
		err = helmExec.RunHelmCommand(args, file, &stderr)
		if err != nil {
			return fmt.Errorf("helm command failed: %s: %w", stderr.String(), err)
		}
	} else if config.ManifestURL != "" {
		err := downloadFile(config.Filename, config.ManifestURL)
		if err != nil {
			return fmt.Errorf("failed to download manifest: %w", err)
		}
	} else if len(config.ManifestPath) > 0 {
		files := make([]string, 0)
		dstFilePath := filepath.Join("working/pre", config.Name+".yaml")
		for _, manifestPath := range config.ManifestPath {
			srcPath := filepath.Join("input", manifestPath)

			foundFiles, err := FindManifests(srcPath)
			if err != nil {
				return fmt.Errorf("error finding manifests: %w", err)
			}
			files = append(files, foundFiles...)
		}
		if len(files) < 1 {
			return fmt.Errorf("no manifests found: %s", config.ManifestPath)
		}
		// Copy the first file
		err = CopyFile(files[0], dstFilePath)
		if err != nil {
			return fmt.Errorf("failed to copy file: %w", err)
		}
		// Append the rest
		dstFile, err := os.OpenFile(dstFilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0)
		if err != nil {
			return fmt.Errorf("error opening file: %w", err)
		}
		defer dstFile.Close()
		for _, value := range files[1:] {
			// add separator
			dstFile.WriteString("\n---\n")
			data, _ := os.ReadFile(value)
			dstFile.Write(data)
		}
	}

	return nil
}

func FindManifests(startPath string) ([]string, error) {

	files := make([]string, 0)
	err := filepath.Walk(startPath, func(path string, info os.FileInfo, err error) error {
		if filepath.Ext(path) == ".yaml" {
			files = append(files, path)
		}
		return nil
	})

	return files, err
}

func CopyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

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
func ReplaceStringInFile(filePath, originalString, desiredString string) error {
	// Read the file content
	content, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("failed to read file: %w", err)
	}

	// Replace the original string with the desired string
	updatedContent := strings.ReplaceAll(string(content), originalString, desiredString)

	// Write the updated content back to the file
	err = os.WriteFile(filePath, []byte(updatedContent), 0644)
	if err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}
func CopyDir(src string, dst string, copydotfiles bool) error {
	// Get properties of the source directory
	srcInfo, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("failed to get source directory info: %w", err)
	}

	// Create the destination directory
	err = os.MkdirAll(dst, srcInfo.Mode())
	if err != nil {
		return fmt.Errorf("failed to create destination directory: %w", err)
	}

	// Walk through the source directory
	err = filepath.Walk(src, func(srcPath string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if copydotfiles {
			// Skip .git, .DS_Store, and .gitkeep
			if info.IsDir() && info.Name() == ".git" {
				return filepath.SkipDir
			}
			if info.Name() == ".DS_Store" || info.Name() == ".gitkeep" {
				return nil
			}
		}
		// Create the destination path
		relPath, err := filepath.Rel(src, srcPath)
		if err != nil {
			return err
		}
		dstPath := filepath.Join(dst, relPath)

		// If it's a directory, create it
		if info.IsDir() {
			err = os.MkdirAll(dstPath, info.Mode())
			if err != nil {
				return fmt.Errorf("failed to create directory %s: %w", dstPath, err)
			}
			return nil
		}

		// If it's a file, copy it
		err = CopyFile(srcPath, dstPath)
		if err != nil {
			return fmt.Errorf("failed to copy file %s to %s: %w", srcPath, dstPath, err)
		}

		return nil
	})

	if err != nil {
		return fmt.Errorf("failed to walk source directory: %w", err)
	}

	return nil
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

// isClusterScoped checks if a given resource is cluster-scoped.
func IsClusterScoped(resourceName, apiVersion string) bool {
	for _, resource := range clusterScopedResources {
		if strings.EqualFold(resource.Name, resourceName) && strings.EqualFold(resource.APIVersion, apiVersion) {
			return true
		}
	}
	return false
}

func RunCommand(cmd string) error {
	output, err := exec.Command("sh", "-c", cmd).CombinedOutput()
	if err != nil {
		log.Fatalf("Command %s failed: %v\nOutput: %s", cmd, err, string(output))
	}
	log.Info(string(output))
	return nil
}

const applicationTemplate = `---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "{{ .SyncWave }}"
  name: {{ .Name }}
  namespace: argocd
spec:
  destination:
    namespace: argocd
    server: 'https://kubernetes.default.svc'
  source:
    path: {{ .GitopsPathPrefix }}{{ .Name }}
    repoURL: '{{ .GitopsUrl }}'
    targetRevision: {{ .GitopsBranch }}
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
`

func CreateApplicationFile(config Config, outputPath string) error {
	// Parse the template
	tmpl, err := template.New("application").Parse(applicationTemplate)
	if err != nil {
		return fmt.Errorf("failed to parse template: %w", err)
	}

	// Execute the template with the config data
	var rendered bytes.Buffer
	if err := tmpl.Execute(&rendered, config); err != nil {
		return fmt.Errorf("failed to execute template: %w", err)
	}
	// create the directory
	if err := os.MkdirAll(outputPath, 0755); err != nil {
		return fmt.Errorf("failed to create directory: %w", err)
	}

	// Write the output to a file
	if err := os.WriteFile(outputPath+"/"+config.Name+".yaml", rendered.Bytes(), 0644); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}
func CleanDescFromResources(dir string) {
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && (strings.HasPrefix(d.Name(), "CustomResourceDefinition") || strings.HasPrefix(d.Name(), "GatewayClass")) && strings.HasSuffix(d.Name(), ".yaml") {
			err := processFile(path)
			if err != nil {
				log.Printf("Error processing file %s: %v\n", path, err)
			}
		}
		return nil
	})
	if err != nil {
		log.Fatalf("Error walking directory: %v\n", err)
	}
}
func processFile(filePath string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("failed to read file: %v", err)
	}
	var content map[string]interface{}
	err = yaml.Unmarshal(data, &content)
	if err != nil {
		return fmt.Errorf("failed to parse YAML: %v", err)
	}
	removeDescription(content)
	updatedData, err := StructToYAML(content)
	if err != nil {
		return fmt.Errorf("failed to marshal updated YAML: %v", err)
	}
	err = os.WriteFile(filePath, updatedData, 0644)
	if err != nil {
		return fmt.Errorf("failed to write updated YAML to file: %v", err)
	}
	return nil
}

func removeDescription(node interface{}) {
	switch node := node.(type) {
	case map[interface{}]interface{}:
		for key, value := range node {
			if key == "description" {
				delete(node, key)
				continue
			}
			removeDescription(value)
		}
	case map[string]interface{}:
		for key, value := range node {
			if key == "description" {
				delete(node, key)
				continue
			}
			removeDescription(value)
		}
	case []interface{}:
		for _, item := range node {
			removeDescription(item)
		}
	}
}

func InjectSyncWaveDynamic(filename, value string) error {
	// Read the YAML file
	data, err := os.ReadFile(filename)
	if err != nil {
		return fmt.Errorf("failed to read file: %w", err)
	}

	// Parse the YAML into a generic map
	var yamlData map[interface{}]interface{}
	if err := yaml.Unmarshal(data, &yamlData); err != nil {
		return fmt.Errorf("failed to parse YAML: %w", err)
	}

	// Navigate to metadata.annotations dynamically
	metadata, ok := yamlData["metadata"].(map[interface{}]interface{})
	if !ok {
		metadata = make(map[interface{}]interface{})
		yamlData["metadata"] = metadata
	}

	annotations, ok := metadata["annotations"].(map[interface{}]interface{})
	if !ok {
		annotations = make(map[interface{}]interface{})
		metadata["annotations"] = annotations
	}

	// Add or update the annotation
	fixedKey := "argocd.argoproj.io/sync-wave"
	annotations[fixedKey] = value

	// Marshal the updated YAML back
	updatedData, err := yaml.Marshal(&yamlData)
	if err != nil {
		return fmt.Errorf("failed to marshal updated YAML: %w", err)
	}

	// Write the updated YAML back to the file
	if err := os.WriteFile(filename, updatedData, os.ModePerm); err != nil {
		return fmt.Errorf("failed to write updated YAML to file: %w", err)
	}

	return nil
}

func StructToYAML(value interface{}) ([]byte, error) {
	var valueBuffer bytes.Buffer
	// valueBuffer.Write([]byte("---\n"))
	yamlEncoder := yaml.NewEncoder(&valueBuffer)
	yamlEncoder.SetIndent(2)
	err := yamlEncoder.Encode(&value)
	if err != nil {
		return nil, err
	}
	validYAML := append([]byte("---\n"), valueBuffer.Bytes()...)
	return validYAML, nil

}

const appConfigmapTemplate = `---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clusterforge-{{ .Name }}-info
  namespace: {{.Namespace}}
data:
  source.yaml: |
{{ .Source }}
`

type appConfig struct {
	Name      string
	Namespace string
	Source    string
}

func CreateConfigmapFile(config Config, source string, outputPath string) error {
	sourceLines := strings.Split(source, "\n")
	indentedSource := "    " + strings.Join(sourceLines, "\n    ")
	tmpl, err := template.New("configmap").Parse(appConfigmapTemplate)
	if err != nil {
		return fmt.Errorf("failed to parse template: %w", err)
	}

	var rendered bytes.Buffer
	if err := tmpl.Execute(&rendered, appConfig{Name: config.Name, Namespace: getPrimaryNamespace(config), Source: indentedSource}); err != nil {
		return fmt.Errorf("failed to execute template: %w", err)
	}

	if err := os.MkdirAll(outputPath, 0755); err != nil {
		return fmt.Errorf("failed to create directory: %w", err)
	}

	if err := os.WriteFile(outputPath+"/ConfigMap-clusterforge-"+config.Name+"-info.yaml", rendered.Bytes(), 0644); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}
