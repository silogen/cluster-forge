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

package main

import (
	"fmt"
	"os"

	"github.com/silogen/cluster-forge/cmd/caster"
	"github.com/silogen/cluster-forge/cmd/smelter"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

func main() {
	var rootCmd = &cobra.Command{Use: "app"}
	var configFile string
	var imageName string
	var stackName string
	var gitopsUrl string
	var gitopsBranch string
	var gitopsPathPrefix string
	var persistentGitea bool
	var nonInteractive bool
	var smeltCmd = &cobra.Command{
		Use:   "smelt",
		Short: "Run smelt",
		Long: `The smelt command processes the input configuration and performs the smelting operation.
It reads the configuration from the input directory and generates normalized yaml in the working directory.
This output can then be edited or customized if needed before casting.

The reason for customizing is to create cluster specific configurations.
For example, you could template a 'baseDomain' which could then be input and templated at the forge step.`,
		Run: func(cmd *cobra.Command, args []string) {
			gitops := utils.GitopsParameters{Url: gitopsUrl, Branch: gitopsBranch, PathPrefix: gitopsPathPrefix}
			runSmelt(configFile, nonInteractive, gitops)
		},
	}

	var castCmd = &cobra.Command{
		Use:   "cast",
		Short: "Run cast",
		Long: `The cast command processes the normalized (and possibly custom templated) yaml from the working directory and performs the casting operation.

This step creates a container image which can be used during forge step to deploy all the components in a stack to a cluster.`,
		PreRun: func(cmd *cobra.Command, args []string) {
			if nonInteractive {
				cmd.MarkFlagRequired("imageName")
				cmd.MarkFlagRequired("stackName")
			}
		},
		Run: func(cmd *cobra.Command, args []string) {
			gitops := utils.GitopsParameters{Url: gitopsUrl, Branch: gitopsBranch, PathPrefix: gitopsPathPrefix}
			runCast(true, configFile, imageName, stackName, persistentGitea, nonInteractive, gitops)
		},
	}

	var forgeCmd = &cobra.Command{
		Use:   "forge",
		Short: "Run forge",
		Long:  `The forge command will run both smelt and cast, and create ephemeral image.`,

		Run: func(cmd *cobra.Command, args []string) {
			gitops := utils.GitopsParameters{Url: gitopsUrl, Branch: gitopsBranch, PathPrefix: gitopsPathPrefix}
			runForge(gitops)
		},
	}
	defaultConfigfile := "input/config.yaml"
	defaultGitopsUrl := "http://gitea-http.cf-gitea.svc:3000/forge/clusterforge.git"
	defaultGitopsBranch := "HEAD"
	defaultGitopsPathPrefix := ""

	rootCmd.AddCommand(smeltCmd, castCmd, forgeCmd)

	rootCmd.PersistentFlags().StringVarP(&configFile, "config", "c", defaultConfigfile, "Path to the config file")
	rootCmd.PersistentFlags().BoolVarP(&nonInteractive, "non-interactive", "n", false, "Non-interactive, fail if information is missing.")
	rootCmd.PersistentFlags().StringVarP(&gitopsUrl, "gitopsUrl", "", defaultGitopsUrl, "Url target for Argocd app")
	rootCmd.PersistentFlags().StringVarP(&gitopsBranch, "gitopsBranch", "", defaultGitopsBranch, "Url target for Argocd app")
	rootCmd.PersistentFlags().StringVarP(&gitopsPathPrefix, "gitopsPathPrefix", "", defaultGitopsPathPrefix, "Prefix for Argocd app target path")

	castCmd.Flags().BoolVarP(&persistentGitea, "persistent", "p", false, "If set to true, gitea will use a pvc for its data")
	castCmd.Flags().StringVarP(&imageName, "imageName", "i", "", "Name of docker image to push, you need either both stackName and imageName or neither")
	castCmd.Flags().StringVarP(&stackName, "stackName", "s", "", "Name of stack, you need either both stackName and imageName or neither")
	castCmd.MarkFlagsRequiredTogether("imageName", "stackName")

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func runSmelt(configFile string, nonInteractive bool, gitops utils.GitopsParameters) {
	workingDir := "./working"
	filesDir := "./output"
	utils.Setup(nonInteractive)
	log.Println("starting up...")
	configs, err := utils.LoadConfig(configFile, gitops)
	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Printf("Read config for : %+v", config.Name)
	}
	if !nonInteractive {
		fmt.Print(utils.ForgeLogo)
		fmt.Println("Smelting")
	} else {
		log.Println("Config: " + configFile)
	}
	smelter.Smelt(configs, workingDir, filesDir, configFile, nonInteractive)
}

func runCast(publishImage bool, configFile string, imageName string, stackName string, persistentGitea bool, nonInteractive bool, gitops utils.GitopsParameters) string {
	stacksDir := "./stacks"
	filesDir := "./working"
	utils.Setup(nonInteractive)
	log.Println("starting up...")
	configs, err := utils.LoadConfig(configFile, gitops)

	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Printf("Read config for : %+v", config.Name)
	}
	if !nonInteractive {
		fmt.Print(utils.ForgeLogo)
		fmt.Println("Casting")
	} else {
		log.Println("Config: " + configFile + " image: " + imageName + " stack: " + stackName)
	}
	stack := caster.Cast(filesDir, stacksDir, publishImage, imageName, stackName, persistentGitea, nonInteractive)
	return stack
}

func runForge(gitops utils.GitopsParameters) {
	runSmelt("input/config.yaml", false, gitops)
	stack := runCast(false, "input/config.yaml", "", "", false, false, gitops)
	log.Printf("Stackname: %s", stack)
}
