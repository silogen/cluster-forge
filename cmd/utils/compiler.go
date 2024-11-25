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
	"embed"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"
)

//go:embed templates/*
var tplFolder embed.FS
var htemp *template.Template
var ftemp *template.Template
var cmtemp *template.Template

// Declare type pointer to a template
var temp *template.Template

// Using the init function to make sure the template is only parsed once in the program
func init() {
	// template.Must takes the reponse of template.ParseFiles and does error checking
	temp = template.Must(template.ParseFS(tplFolder, "templates/template.templ"))
	htemp = template.Must(template.ParseFS(tplFolder, "templates/header.templ"))
	ftemp = template.Must(template.ParseFS(tplFolder, "templates/footer.templ"))
	cmtemp = template.Must(template.ParseFS(tplFolder, "templates/configmapheader.templ"))
}

type platformpackage struct {
	Name    string
	Kind    string
	Content bytes.Buffer
	Index   int
	Type    string
}

func shouldSkipFile(file os.DirEntry, dirPath string) bool {
	if file.IsDir() {
		return true
	}
	name := file.Name()
	content, err := os.ReadFile(dirPath + "/" + name)
	if err != nil {
		log.Printf("Error reading file %s: %v", name, err)
		return true
	}
	if strings.Contains(string(content), "helm.sh/hook") {
		return true
	}

	return false
}

const maxFileSize = 300 * 1024 // 300KB

func CreateCrossplaneObject(config Config, basePath string, workingBasePath string) error {
	if config.HelmURL == "" && config.SourceFile == "" && config.ManifestURL == "" {
		return fmt.Errorf("config '%s' is invalid: at least one of HelmURL, SourceFile, or ManifestURL must be provided", config.Name)
	}
	if config.Namespace == "" {
		return fmt.Errorf("config '%s' is invalid: Namespace must not be empty", config.Name)
	}
	platformPackage := &platformpackage{Name: config.Name}

	createNewFile := func(baseName, suffix string, index int) (*os.File, error) {
		fileName := fmt.Sprintf("%s/%s-%s-%d.yaml", basePath, suffix, baseName, index)
		return os.OpenFile(fileName, os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
	}

	fileHandles := openFiles(platformPackage.Name, createNewFile)
	defer closeFiles(fileHandles)

	workingDir := filepath.Join(workingBasePath, platformPackage.Name)
	files, err := os.ReadDir(workingDir)
	if err != nil {
		return fmt.Errorf("failed to read working directory '%s': %w", workingDir, err)
	}

	for _, file := range files {
		if shouldSkipFile(file, workingDir) {
			continue
		}

		platformPackage.Kind = parseKindFromFileName(file.Name())
		fileContent, err := os.ReadFile(filepath.Join(workingDir, file.Name()))
		if err != nil {
			return fmt.Errorf("failed to read file '%s': %w", file.Name(), err)
		}

		processContent(&platformPackage.Content, string(fileContent), platformPackage.Kind)

		currentFile, currentFileIndex, fileType := getFileDetails(fileHandles, platformPackage.Kind)

		handleFileSize(currentFile, platformPackage, currentFileIndex, fileType)
		writeContentToFile(currentFile, platformPackage.Content.String(), fileType, platformPackage)

		platformPackage.Content.Reset()
	}

	removeEmptyLinesFromFiles(fileHandles)
	return nil
}

func openFiles(baseName string, createNewFile func(string, string, int) (*os.File, error)) map[string]*os.File {
	fileHandles := make(map[string]*os.File)
	resourceTypes := []string{"crd", "namespace", "object", "secret", "externalsecret"}
	for _, resourceType := range resourceTypes {
		file, err := createNewFile(baseName, resourceType, 1)
		if err != nil {
			log.Fatalf("failed to create file: %v", err)
		}
		fileHandles[resourceType] = file
	}
	return fileHandles
}

func closeFiles(fileHandles map[string]*os.File) {
	for _, file := range fileHandles {
		file.Close()
	}
}

func parseKindFromFileName(fileName string) string {
	parts := strings.Split(fileName, "_")
	if len(parts) < 2 {
		log.Fatalf("Invalid file name format: %s. Expected format 'kind_metadata.yaml'", fileName)
	}
	return strings.TrimSuffix(parts[0]+"-"+parts[1], ".yaml")
}

func processContent(buffer *bytes.Buffer, content, kind string) {
	lines := strings.Split(content, "\n")
	kindParts := strings.Split(kind, "-")

	if kindParts[0] == "CustomResourceDefinition" || kindParts[0] == "Namespace" {
		buffer.WriteString("---\n")
		for _, line := range lines {
			buffer.WriteString(line + "\n")
		}
	} else {
		for _, line := range lines {
			buffer.WriteString("          " + line + "\n")
		}
	}
}

func getFileDetails(fileHandles map[string]*os.File, kind string) (*os.File, *int, string) {
	switch {
	case strings.Contains(kind, "CustomResourceDefinition"):
		return fileHandles["crd"], new(int), "crd"
	case strings.Contains(kind, "Namespace"):
		return fileHandles["namespace"], new(int), "namespace"
	case strings.Contains(kind, "ExternalSecret"):
		return fileHandles["externalsecret"], new(int), "externalsecret"
	case strings.Contains(kind, "Secret"):
		return fileHandles["secret"], new(int), "secret"
	default:
		return fileHandles["object"], new(int), "object"
	}
}

func handleFileSize(
	currentFile *os.File,
	packageData *platformpackage,
	currentFileIndex *int,
	fileType string,
) {
	currentFileSize, _ := currentFile.Seek(0, io.SeekEnd)
	if int(currentFileSize)+packageData.Content.Len() > maxFileSize {
		*currentFileIndex++
		newFileName := fmt.Sprintf("output/%s-%s-%d.yaml", fileType, packageData.Name, *currentFileIndex)
		newFile, err := os.OpenFile(newFileName, os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			log.Fatalf("failed to create new file: %v", err)
		}
		currentFile.Close()
		*currentFile = *newFile
	}
	if currentFileIndex != nil {
		packageData.Index = *currentFileIndex
		packageData.Type = fileType
		if fileType != "crd" {
			err := cmtemp.Execute(currentFile, packageData)
			if err != nil {
				log.Fatalf("failed to write header: %v", err)
			}
		}
	}
}

func createNewFileSafely(baseName, fileType string, index int, currentFile *os.File) (*os.File, error) {
	currentFile.Close()
	return os.OpenFile(fmt.Sprintf("output/%s-%s-%d.yaml", fileType, baseName, index), os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
}

func writeFileHeader(file *os.File, packageData *platformpackage, fileType string) {
	packageData.Index++
	packageData.Type = fileType

	if fileType != "crd" {
		if err := cmtemp.Execute(file, packageData); err != nil {
			log.Fatalf("Failed to write file header for '%s': %v", fileType, err)
		}
	}
}

func writeContentToFile(file *os.File, content string, fileType string, platformPackage *platformpackage) {
	if fileType == "crd" || fileType == "namespace" {
		if _, err := file.Write([]byte(content)); err != nil {
			log.Fatalf("Failed to write content to file '%s': %v", fileType, err)
		}
	} else {
		platformPackage.Type = strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(strings.TrimSuffix(content, ".yaml"), "_", "-"), ":", ""))
		if err := temp.Execute(file, platformPackage); err != nil {
			log.Fatalf("Failed to execute template for file '%s': %v", fileType, err)
		}
	}
}

func removeEmptyLinesFromFiles(fileHandles map[string]*os.File) {
	for _, file := range fileHandles {
		removeEmptyLines(file.Name())
	}
}

func removeEmptyLines(filename string) error {
	data, err := os.ReadFile(filename)
	if err != nil {
		return err
	}

	re := regexp.MustCompile(`(?m)^\s*$[\r\n]*|[\r\n]+\s+\z`)
	result := re.ReplaceAllString(string(data), "")

	err = os.WriteFile(filename, []byte(result), os.ModePerm)
	if err != nil {
		return err
	}

	return nil
}

func copyFile(src, dst string) error {
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
