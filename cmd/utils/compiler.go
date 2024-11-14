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
	// Skip directories
	if file.IsDir() {
		return true
	}
	name := file.Name()
	// Check if file contains helm.sh/hook
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

// CreateCrossplaneObject reads the output of the SplitYAML function and writes it to a file
func CreateCrossplaneObject(config Config) {
	// read a command line argument and assign it to a variable
	const maxFileSize = 300 * 1024 // 300KB

	platformpackage := new(platformpackage)
	platformpackage.Name = config.Name

	createNewFile := func(baseName, suffix string, index int) (*os.File, error) {
		if suffix == "crd" {
			return os.OpenFile(fmt.Sprintf("output/crd-%s-%d.yaml", baseName, index), os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
		} else {
			return os.OpenFile(fmt.Sprintf("output/cm-%s-%s-%d.yaml", baseName, suffix, index), os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
		}
	}

	objectFileIndex, crdFileIndex, secretFileIndex, externalsecretFileIndex := 1, 1, 1, 1
	objectFile, err := createNewFile(platformpackage.Name, "object", objectFileIndex)
	if err != nil {
		log.Fatalln(err)
	}
	defer objectFile.Close()

	crdFile, err := createNewFile(platformpackage.Name, "crd", crdFileIndex)
	if err != nil {
		log.Fatalln(err)
	}
	defer crdFile.Close()

	secretFile, err := createNewFile(platformpackage.Name, "secret", secretFileIndex)
	if err != nil {
		log.Fatalln(err)
	}
	defer secretFile.Close()

	externalSecretFile, err := createNewFile(platformpackage.Name, "externalsecret", externalsecretFileIndex)
	if err != nil {
		log.Fatalln(err)
	}
	defer externalSecretFile.Close()

	files, _ := os.ReadDir("working/" + platformpackage.Name)
	for _, file := range files {
		if shouldSkipFile(file, "working/"+platformpackage.Name) {
			continue
		}
		platformpackage.Kind = strings.Split(file.Name(), "_")[0] + "-" + strings.Split(file.Name(), "_")[1]
		platformpackage.Kind = strings.TrimSuffix(platformpackage.Kind, ".yaml")
		content, err := os.ReadFile("working/" + platformpackage.Name + "/" + file.Name())
		if err != nil {
			log.Fatalln(err)
		}
		lines := strings.Split(string(content), "\n")
		kindParts := strings.Split(platformpackage.Kind, "-")

		if kindParts[0] == "CustomResourceDefinition" {
			platformpackage.Content.WriteString("---\n")
			for _, line := range lines {
				platformpackage.Content.WriteString(fmt.Sprintf("%s\n", line))
			}
		} else {
			for _, line := range lines {
				// Line Indenting
				platformpackage.Content.WriteString(fmt.Sprintf("          %s\n", line))
			}
		}

		// for _, line := range lines {
		//	// Line Indenting
		//	platformpackage.Content.WriteString(fmt.Sprintf("          %s\n", line))
		// }

		var currentFile *os.File
		var currentFileSize int64
		var currentFileIndex *int
		var currentFileType string

		switch {
		case strings.Contains(platformpackage.Kind, "CustomResourceDefinition"):
			currentFile = crdFile
			currentFileSize, _ = crdFile.Seek(0, os.SEEK_END)
			currentFileIndex = &crdFileIndex
			currentFileType = "crd"
		case strings.Contains(platformpackage.Kind, "ExternalSecret"):
			currentFile = externalSecretFile
			currentFileSize, _ = externalSecretFile.Seek(0, os.SEEK_END)
			currentFileIndex = &externalsecretFileIndex
			currentFileType = "externalsecret"
		case strings.Contains(platformpackage.Kind, "Secret"):
			currentFile = secretFile
			currentFileSize, _ = secretFile.Seek(0, os.SEEK_END)
			currentFileIndex = &secretFileIndex
			currentFileType = "secret"
		default:
			currentFile = objectFile
			currentFileSize, _ = objectFile.Seek(0, os.SEEK_END)
			currentFileIndex = &objectFileIndex
			currentFileType = "object"
		}

		if currentFileSize == 0 {
			// Write the header to the file
			platformpackage.Index = *currentFileIndex
			platformpackage.Type = currentFileType
			if currentFileType != "crd" {
				err = cmtemp.Execute(currentFile, platformpackage)
				if err != nil {
					log.Fatalln(err)
				}
			}
		}

		if currentFileSize+int64(platformpackage.Content.Len()) > maxFileSize {
			*currentFileIndex++
			currentFile, err = createNewFile(platformpackage.Name, currentFileType, *currentFileIndex)
			if err != nil {
				log.Fatalln(err)
			}
			defer currentFile.Close() // Ensure the new file is closed after use
			// Write the header to the file
			platformpackage.Index = *currentFileIndex
			platformpackage.Type = currentFileType
			if currentFileType != "crd" {
				err = cmtemp.Execute(currentFile, platformpackage)
				if err != nil {
					log.Fatalln(err)
				}
			}
		}

		if currentFileType == "crd" {
			_, err = currentFile.Write(platformpackage.Content.Bytes())
			if err != nil {
				log.Fatalln(err)
			}
		} else {
			platformpackage.Type = strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(strings.TrimSuffix(file.Name(), ".yaml"), "_", "-"), ":", ""))
			err = temp.Execute(currentFile, platformpackage)
			if err != nil {
				log.Fatalln(err)
			}
		}
		platformpackage.Content.Reset()
	}

	// Close the initial files explicitly after the loop
	objectFile.Close()
	crdFile.Close()
	secretFile.Close()
	externalSecretFile.Close()
	removeEmptyLines(objectFile.Name())
	removeEmptyLines(crdFile.Name())
	removeEmptyLines(secretFile.Name())
	removeEmptyLines(externalSecretFile.Name())

}

// CreatePackage reads the output of the SplitYAML function and writes it to a file
func CreatePackage(config Config, part string, content string) {
	platformpackage := new(platformpackage)
	platformpackage.Name = config.CastName + "-" + config.Name
	outfile, err := os.OpenFile("packages/"+config.CastName+"-"+config.Name+"-"+part+"-packages.yaml", os.O_TRUNC|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Fatalln(err)
	}
	defer outfile.Close()
	// read ebedded filesystem file header.templ and echo into outfile
	err = htemp.Execute(outfile, platformpackage)
	if err != nil {
		log.Fatalln(err)
	}
	lines := strings.Split(string(content), "\n")

	// Append content to outfile
	contentToAppend := strings.Join(lines, "\n")
	_, err = io.WriteString(outfile, contentToAppend)
	if err != nil {
		log.Fatalln(err)
	}
	// Execute the footer template
	err = ftemp.Execute(outfile, platformpackage)
	if err != nil {
		log.Fatalln(err)
	}
	removeEmptyLines("packages/" + config.CastName + "-" + config.Name + "-" + part + "-packages.yaml")
}

func removeEmptyLines(filename string) error {
	// Read the file
	data, err := os.ReadFile(filename)
	if err != nil {
		return err
	}

	// Remove empty lines
	re := regexp.MustCompile(`(?m)^\s*$[\r\n]*|[\r\n]+\s+\z`)
	result := re.ReplaceAllString(string(data), "")

	// Write the result back to the file
	err = os.WriteFile(filename, []byte(result), os.ModePerm)
	if err != nil {
		return err
	}

	return nil
}
