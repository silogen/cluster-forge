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
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseImageName(t *testing.T) {
	tests := []struct {
		image      string
		registry   string
		repository string
		tag        string
	}{
		{
			image:      "nginx:1.21",
			registry:   "docker.io",
			repository: "library/nginx",
			tag:        "1.21",
		},
		{
			image:      "docker.io/library/nginx:1.21",
			registry:   "docker.io",
			repository: "library/nginx",
			tag:        "1.21",
		},
		{
			image:      "registry.k8s.io/kube-proxy:v1.28.0",
			registry:   "registry.k8s.io",
			repository: "kube-proxy",
			tag:        "v1.28.0",
		},
		{
			image:      "quay.io/prometheus/prometheus:v2.40.0",
			registry:   "quay.io",
			repository: "prometheus/prometheus",
			tag:        "v2.40.0",
		},
		{
			image:      "ubuntu",
			registry:   "docker.io",
			repository: "library/ubuntu",
			tag:        "latest",
		},
	}

	for _, test := range tests {
		registry, repository, tag := parseImageName(test.image)
		if registry != test.registry || repository != test.repository || tag != test.tag {
			t.Errorf("parseImageName(%s) = (%s, %s, %s), want (%s, %s, %s)",
				test.image, registry, repository, tag,
				test.registry, test.repository, test.tag)
		}
	}
}

func TestExtractContainerImages(t *testing.T) {
	yamlContent := `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deployment
spec:
  template:
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
      - name: sidecar
        image: registry.k8s.io/kube-proxy:v1.28.0
      initContainers:
      - name: init
        image: busybox:latest
`

	images, err := extractContainerImages(yamlContent)
	if err != nil {
		t.Fatalf("extractContainerImages failed: %v", err)
	}

	expectedImages := []string{"nginx:1.21", "registry.k8s.io/kube-proxy:v1.28.0", "busybox:latest"}
	if len(images) != len(expectedImages) {
		t.Errorf("Expected %d images, got %d", len(expectedImages), len(images))
	}

	imageMap := make(map[string]bool)
	for _, img := range images {
		imageMap[img] = true
	}

	for _, expected := range expectedImages {
		if !imageMap[expected] {
			t.Errorf("Expected image %s not found in extracted images", expected)
		}
	}
}

func TestFindYAMLFiles(t *testing.T) {
	// Create a temporary directory structure
	tempDir, err := os.MkdirTemp("", "test-yaml-files")
	if err != nil {
		t.Fatalf("Failed to create temp directory: %v", err)
	}
	defer os.RemoveAll(tempDir)

	// Create test files
	testFiles := []string{
		"deployment.yaml",
		"service.yml",
		"config.txt",
		"subdir/pod.yaml",
		"pre/ignored.yaml",
		"argo-apps/app.yaml",
	}

	for _, file := range testFiles {
		dir := filepath.Dir(filepath.Join(tempDir, file))
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatalf("Failed to create directory: %v", err)
		}
		if err := os.WriteFile(filepath.Join(tempDir, file), []byte("test content"), 0644); err != nil {
			t.Fatalf("Failed to create test file: %v", err)
		}
	}

	yamlFiles, err := findYAMLFiles(tempDir)
	if err != nil {
		t.Fatalf("findYAMLFiles failed: %v", err)
	}

	// Should find deployment.yaml, service.yml, and subdir/pod.yaml
	// Should ignore pre/ignored.yaml and argo-apps/app.yaml
	expectedCount := 3
	if len(yamlFiles) != expectedCount {
		t.Errorf("Expected %d YAML files, got %d", expectedCount, len(yamlFiles))
	}

	// Check that ignored files are not included
	for _, file := range yamlFiles {
		if strings.Contains(file, "/pre/") || strings.Contains(file, "/argo-apps/") {
			t.Errorf("Should not include files from pre or argo-apps directories: %s", file)
		}
	}
}

func TestReplaceImageTagsInContent(t *testing.T) {
	content := `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deployment
spec:
  template:
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
      - name: sidecar
        image: registry.k8s.io/kube-proxy:v1.28.0
`

	imageInfos := []ImageInfo{
		{
			Registry:   "docker.io",
			Repository: "library/nginx",
			Tag:        "1.21",
			SHA:        "sha256:abc123",
			FullImage:  "nginx:1.21",
		},
		{
			Registry:   "registry.k8s.io",
			Repository: "kube-proxy",
			Tag:        "v1.28.0",
			SHA:        "sha256:def456",
			FullImage:  "registry.k8s.io/kube-proxy:v1.28.0",
		},
	}

	result := replaceImageTagsInContent(content, imageInfos)

	// Check that tags are replaced with SHA values
	if !strings.Contains(result, "nginx@sha256:abc123") {
		t.Error("nginx image should be replaced with SHA")
	}
	if !strings.Contains(result, "registry.k8s.io/kube-proxy@sha256:def456") {
		t.Error("kube-proxy image should be replaced with SHA")
	}

	// Check that comments with original tags are added
	if !strings.Contains(result, "# Original tag: 1.21") {
		t.Error("Original tag comment should be added for nginx")
	}
	if !strings.Contains(result, "# Original tag: v1.28.0") {
		t.Error("Original tag comment should be added for kube-proxy")
	}
}

func TestGetImageSHASkipsQuayIO(t *testing.T) {
	testCases := []struct {
		image       string
		shouldSkip  bool
		description string
	}{
		{
			image:       "quay.io/prometheus/prometheus:v2.40.0",
			shouldSkip:  true,
			description: "Should skip quay.io images",
		},
		{
			image:       "nginx:1.21",
			shouldSkip:  false,
			description: "Should not skip docker.io images",
		},
		{
			image:       "registry.k8s.io/kube-proxy:v1.28.0",
			shouldSkip:  false,
			description: "Should not skip registry.k8s.io images",
		},
		{
			image:       "gcr.io/google-containers/test:latest",
			shouldSkip:  false,
			description: "Should not skip gcr.io images",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.description, func(t *testing.T) {
			imageInfo, err := getImageSHA(tc.image)
			
			if tc.shouldSkip {
				if err == nil || !strings.Contains(err.Error(), "skipping quay.io image") {
					t.Errorf("Expected to skip quay.io image %s, but got: %v", tc.image, err)
				}
				if imageInfo != nil {
					t.Errorf("Expected nil imageInfo for skipped quay.io image, but got: %v", imageInfo)
				}
			} else {
				// For non-quay.io images, we expect them to fail with network errors in tests
				// (since we're not actually hitting the registries)
				if err != nil && strings.Contains(err.Error(), "skipping quay.io image") {
					t.Errorf("Should not skip non-quay.io image %s", tc.image)
				}
			}
		})
	}
}