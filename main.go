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

	var smeltCmd = &cobra.Command{
		Use:   "smelt",
		Short: "Run smelt",
		Long: `The smelt command processes the input configuration and performs the smelting operation.
It reads the configuration from the input directory and generates normalized yaml in the working directory.
This output can then be edited or customized if needed before casting.

The reason for customizing is to create cluster specific configurations.
For example, you could template a 'baseDomain' which could then be input and templated at the forge step.`,
		Run: func(cmd *cobra.Command, args []string) {
			runSmelt()
		},
	}

	var castCmd = &cobra.Command{
		Use:   "cast",
		Short: "Run cast",
		Long: `The cast command processes the normalized (and possibly custom templated) yaml from the working directory and performs the casting operation.

This step creates a container image which can be used during forge step to deploy all the components in a stack to a cluster.`,

		Run: func(cmd *cobra.Command, args []string) {
			runCast(false)
		},
	}

	var forgeCmd = &cobra.Command{
		Use:   "forge",
		Short: "Run forge",
		Long:  `The forge command will run both smelt and cast, and create ephemeral image.`,

		Run: func(cmd *cobra.Command, args []string) {
			runForge()
		},
	}

	rootCmd.AddCommand(smeltCmd, castCmd, forgeCmd)
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func runSmelt() {
	workingDir := "./working"
	filesDir := "./output"
	utils.Setup()
	log.Println("starting up...")
	configs, err := utils.LoadConfig("input/config.yaml")
	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Printf("Read config for : %+v", config.Name)
	}
	fmt.Print(utils.ForgeLogo)
	fmt.Println("Smelting")
	smelter.Smelt(configs, workingDir, filesDir)
}

func runCast(publishImage bool) {
	workingDir := "./working"
	stacksDir := "./stacks"
	filesDir := "./output"
	utils.Setup()
	log.Println("starting up...")
	configs, err := utils.LoadConfig("input/config.yaml")
	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Printf("Read config for : %+v", config.Name)
	}
	fmt.Print(utils.ForgeLogo)
	fmt.Println("Casting")
	caster.Cast(configs, filesDir, workingDir, stacksDir, publishImage)
}

func runForge() {
	runSmelt()
	runCast(true)
}
