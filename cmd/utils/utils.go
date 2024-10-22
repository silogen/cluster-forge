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
	"io"
	"net/http"
	"os"
	"os/exec"

	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v2"
)

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

	return configs, nil
}

// Config is the struct for the an individual tool config
type Config struct {
	HelmChartName string `yaml:"helm-chart-name"`
	HelmURL       string `yaml:"helm-url"`
	Values        string `yaml:"values"`
	Secrets       bool   `yaml:"secrets"`
	Name          string `yaml:"name"`
	HelmName      string `yaml:"helm-name"`
	ManifestURL   string `yaml:"manifest-url"`
	HelmVersion   string `yaml:"helm-version"`
	Namespace     string `yaml:"namespace"`
	Filename      string
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
	} else if config.ManifestURL != "" {
		log.Debugf("looking for " + config.ManifestURL)
		err := downloadFile(config.Filename, config.ManifestURL)
		if err != nil {
			log.Fatal(err)
		}
	}
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
