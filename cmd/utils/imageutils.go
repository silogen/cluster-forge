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
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v3"
)

// ImageInfo represents a container image with its original tag and SHA
type ImageInfo struct {
	Registry   string `json:"registry"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	SHA        string `json:"sha"`
	FullImage  string `json:"fullImage"`
}

// DockerHubManifest represents the Docker Hub manifest response
type DockerHubManifest struct {
	MediaType string `json:"mediaType"`
	Config    struct {
		Digest string `json:"digest"`
	} `json:"config"`
}

// DockerHubToken represents the Docker Hub authentication token
type DockerHubToken struct {
	Token string `json:"token"`
}

// ReplaceImageTagsWithSHA processes all YAML files in the working directory
// and replaces container image tags with their SHA values
func ReplaceImageTagsWithSHA(workingDir string) error {
	log.Info("Starting image tag to SHA replacement process...")
	
	// Find all YAML files in the working directory
	yamlFiles, err := findYAMLFiles(workingDir)
	if err != nil {
		return fmt.Errorf("failed to find YAML files: %w", err)
	}

	// Process each YAML file
	for _, yamlFile := range yamlFiles {
		if err := processYAMLFile(yamlFile); err != nil {
			log.Errorf("Failed to process file %s: %v", yamlFile, err)
			// Continue processing other files even if one fails
		}
	}

	log.Info("Completed image tag to SHA replacement process")
	return nil
}

// findYAMLFiles recursively finds all YAML files in the directory
func findYAMLFiles(workingDir string) ([]string, error) {
	var yamlFiles []string
	
	err := filepath.Walk(workingDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		
		// Skip directories and non-YAML files
		if info.IsDir() || (!strings.HasSuffix(strings.ToLower(path), ".yaml") && !strings.HasSuffix(strings.ToLower(path), ".yml")) {
			return nil
		}
		
		// Skip the pre directory and argo-apps directory if they exist
		if strings.Contains(path, "/pre/") || strings.Contains(path, "/argo-apps/") {
			return nil
		}
		
		yamlFiles = append(yamlFiles, path)
		return nil
	})
	
	return yamlFiles, err
}

// processYAMLFile processes a single YAML file to replace image tags with SHA values
func processYAMLFile(filePath string) error {
	log.Debugf("Processing file: %s", filePath)
	
	// Read the file
	content, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("failed to read file %s: %w", filePath, err)
	}
	
	// Find all container images in the file
	images, err := extractContainerImages(string(content))
	if err != nil {
		return fmt.Errorf("failed to extract container images from %s: %w", filePath, err)
	}
	
	if len(images) == 0 {
		log.Debugf("No container images found in %s", filePath)
		return nil
	}
	
	// Get SHA values for all images
	imageInfos := make([]ImageInfo, 0, len(images))
	for _, image := range images {
		imageInfo, err := getImageSHA(image)
		if err != nil {
			log.Warnf("Failed to get SHA for image %s: %v", image, err)
			continue
		}
		imageInfos = append(imageInfos, *imageInfo)
	}
	
	if len(imageInfos) == 0 {
		log.Debugf("No SHA values obtained for images in %s", filePath)
		return nil
	}
	
	// Replace tags with SHA values in the content
	newContent := replaceImageTagsInContent(string(content), imageInfos)
	
	// Write the updated content back to the file
	if err := os.WriteFile(filePath, []byte(newContent), 0644); err != nil {
		return fmt.Errorf("failed to write updated content to %s: %w", filePath, err)
	}
	
	log.Infof("Updated %d image(s) in %s", len(imageInfos), filePath)
	return nil
}

// extractContainerImages extracts container image references from YAML content
func extractContainerImages(content string) ([]string, error) {
	var images []string
	imageMap := make(map[string]bool) // To avoid duplicates
	
	// Regular expression to match container image references
	// This matches patterns like:
	// - nginx:1.21
	// - docker.io/library/nginx:1.21
	// - registry.k8s.io/kube-proxy:v1.28.0
	// - quay.io/prometheus/prometheus:v2.40.0
	imageRegex := regexp.MustCompile(`(?i)(?:^|\s+)(?:image:\s*["\']?)([a-zA-Z0-9\-_.]+(?:\.[a-zA-Z0-9\-_.]+)*(?::[0-9]+)?/[a-zA-Z0-9\-_.]+(?:/[a-zA-Z0-9\-_.]+)*:[a-zA-Z0-9\-_.]+)`)
	
	// Also match simple image names without registry
	simpleImageRegex := regexp.MustCompile(`(?i)(?:^|\s+)(?:image:\s*["\']?)([a-zA-Z0-9\-_.]+:[a-zA-Z0-9\-_.]+)`)
	
	// Parse YAML to get a more structured approach
	var yamlDoc interface{}
	if err := yaml.Unmarshal([]byte(content), &yamlDoc); err == nil {
		extractImagesFromYAML(yamlDoc, imageMap)
	}
	
	// Also use regex as fallback
	matches := imageRegex.FindAllStringSubmatch(content, -1)
	for _, match := range matches {
		if len(match) > 1 {
			imageMap[match[1]] = true
		}
	}
	
	simpleMatches := simpleImageRegex.FindAllStringSubmatch(content, -1)
	for _, match := range simpleMatches {
		if len(match) > 1 {
			image := match[1]
			// Skip if it already has a registry prefix
			if !strings.Contains(image, "/") {
				imageMap[image] = true
			}
		}
	}
	
	// Convert map to slice
	for image := range imageMap {
		images = append(images, image)
	}
	
	return images, nil
}

// extractImagesFromYAML recursively extracts images from YAML structure
func extractImagesFromYAML(data interface{}, imageMap map[string]bool) {
	switch v := data.(type) {
	case map[string]interface{}:
		for key, value := range v {
			if key == "image" {
				if imageStr, ok := value.(string); ok && strings.Contains(imageStr, ":") {
					imageMap[imageStr] = true
				}
			} else {
				extractImagesFromYAML(value, imageMap)
			}
		}
	case []interface{}:
		for _, item := range v {
			extractImagesFromYAML(item, imageMap)
		}
	}
}

// getImageSHA gets the SHA value for a container image
func getImageSHA(image string) (*ImageInfo, error) {
	log.Debugf("Getting SHA for image: %s", image)
	
	// Parse the image name
	registry, repository, tag := parseImageName(image)
	
	var sha string
	var err error
	
	// Try different registry APIs
	if registry == "docker.io" || registry == "" {
		sha, err = getDockerHubSHA(repository, tag)
	} else if strings.Contains(registry, "gcr.io") || strings.Contains(registry, "registry.k8s.io") {
		sha, err = getGCRSHA(registry, repository, tag)
	} else if strings.Contains(registry, "quay.io") {
		sha, err = getQuaySHA(registry, repository, tag)
	} else {
		// Try generic registry API
		sha, err = getGenericRegistrySHA(registry, repository, tag)
	}
	
	if err != nil {
		return nil, fmt.Errorf("failed to get SHA for %s: %w", image, err)
	}
	
	return &ImageInfo{
		Registry:   registry,
		Repository: repository,
		Tag:        tag,
		SHA:        sha,
		FullImage:  image,
	}, nil
}

// parseImageName parses a container image name into registry, repository, and tag
func parseImageName(image string) (registry, repository, tag string) {
	// Default values
	registry = "docker.io"
	tag = "latest"
	
	// Split by ':'
	parts := strings.Split(image, ":")
	if len(parts) > 1 {
		tag = parts[len(parts)-1]
		image = strings.Join(parts[:len(parts)-1], ":")
	}
	
	// Split by '/'
	pathParts := strings.Split(image, "/")
	if len(pathParts) == 1 {
		// Simple image name like "nginx"
		repository = "library/" + pathParts[0]
	} else if len(pathParts) == 2 {
		// Check if first part is a registry
		if strings.Contains(pathParts[0], ".") || strings.Contains(pathParts[0], ":") {
			// It's a registry
			registry = pathParts[0]
			repository = pathParts[1]
		} else {
			// It's dockerhub user/repo
			repository = strings.Join(pathParts, "/")
		}
	} else {
		// Full path with registry
		registry = pathParts[0]
		repository = strings.Join(pathParts[1:], "/")
	}
	
	return registry, repository, tag
}

// getDockerHubSHA gets SHA from Docker Hub
func getDockerHubSHA(repository, tag string) (string, error) {
	// Get authentication token
	tokenURL := fmt.Sprintf("https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull", repository)
	
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(tokenURL)
	if err != nil {
		return "", fmt.Errorf("failed to get auth token: %w", err)
	}
	defer resp.Body.Close()
	
	var tokenResp DockerHubToken
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", fmt.Errorf("failed to decode token response: %w", err)
	}
	
	// Get manifest
	manifestURL := fmt.Sprintf("https://registry-1.docker.io/v2/%s/manifests/%s", repository, tag)
	req, err := http.NewRequest("GET", manifestURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create manifest request: %w", err)
	}
	
	req.Header.Set("Authorization", "Bearer "+tokenResp.Token)
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	
	resp, err = client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to get manifest: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("manifest request failed with status: %s", resp.Status)
	}
	
	// Get the digest from the response header
	digest := resp.Header.Get("Docker-Content-Digest")
	if digest == "" {
		return "", fmt.Errorf("no digest found in response headers")
	}
	
	return digest, nil
}

// getGCRSHA gets SHA from Google Container Registry or registry.k8s.io
func getGCRSHA(registry, repository, tag string) (string, error) {
	manifestURL := fmt.Sprintf("https://%s/v2/%s/manifests/%s", registry, repository, tag)
	
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", manifestURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create manifest request: %w", err)
	}
	
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to get manifest: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("manifest request failed with status: %s", resp.Status)
	}
	
	// Get the digest from the response header
	digest := resp.Header.Get("Docker-Content-Digest")
	if digest == "" {
		return "", fmt.Errorf("no digest found in response headers")
	}
	
	return digest, nil
}

// getQuaySHA gets SHA from Quay.io
func getQuaySHA(registry, repository, tag string) (string, error) {
	manifestURL := fmt.Sprintf("https://%s/v2/%s/manifests/%s", registry, repository, tag)
	
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", manifestURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create manifest request: %w", err)
	}
	
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to get manifest: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("manifest request failed with status: %s", resp.Status)
	}
	
	// Get the digest from the response header
	digest := resp.Header.Get("Docker-Content-Digest")
	if digest == "" {
		return "", fmt.Errorf("no digest found in response headers")
	}
	
	return digest, nil
}

// getGenericRegistrySHA gets SHA from a generic registry
func getGenericRegistrySHA(registry, repository, tag string) (string, error) {
	manifestURL := fmt.Sprintf("https://%s/v2/%s/manifests/%s", registry, repository, tag)
	
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", manifestURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create manifest request: %w", err)
	}
	
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")
	
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to get manifest: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("manifest request failed with status: %s", resp.Status)
	}
	
	// Get the digest from the response header
	digest := resp.Header.Get("Docker-Content-Digest")
	if digest == "" {
		return "", fmt.Errorf("no digest found in response headers")
	}
	
	return digest, nil
}

// replaceImageTagsInContent replaces image tags with SHA values in the content
func replaceImageTagsInContent(content string, imageInfos []ImageInfo) string {
	var result strings.Builder
	scanner := bufio.NewScanner(strings.NewReader(content))
	
	for scanner.Scan() {
		line := scanner.Text()
		newLine := line
		
		// Check if this line contains an image reference
		for _, imageInfo := range imageInfos {
			if strings.Contains(line, imageInfo.FullImage) {
				// Create the new image reference with SHA
				newImageRef := fmt.Sprintf("%s@%s", strings.Split(imageInfo.FullImage, ":")[0], imageInfo.SHA)
				
				// Replace the tag with SHA and add comment with original tag
				newLine = strings.ReplaceAll(newLine, imageInfo.FullImage, newImageRef)
				
				// Add comment with original tag if it's an image line
				if strings.Contains(line, "image:") {
					newLine = newLine + " # Original tag: " + imageInfo.Tag
				}
			}
		}
		
		result.WriteString(newLine)
		result.WriteString("\n")
	}
	
	return strings.TrimSuffix(result.String(), "\n")
}