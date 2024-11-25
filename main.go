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
	"flag"
	"fmt"

	"github.com/silogen/cluster-forge/cmd/caster"
	"github.com/silogen/cluster-forge/cmd/forger"
	"github.com/silogen/cluster-forge/cmd/smelter"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

func printUsage() {
	fmt.Println(`Usage:
	To setup components, use:
    cluster-forge --smelt

	Or to combine components for deployment, use:
 	cluster-forge --cast

	Or, to deploy to a specific cluster, use:
	cluster-forge --forge --kubeconfig <KUBECONFIG>`)
}

func main() {
	// Define command-line flags for the two modes
	smelt := flag.Bool("smelt", false, "Run smelt")
	cast := flag.Bool("cast", false, "Run cast")
	forge := flag.Bool("forge", false, "Run forge")

	// Parse the command-line flags
	flag.Parse()

	// Determine the selected mode
	selectedMode := ""
	if *smelt {
		selectedMode = "smelt"
	} else if *cast {
		selectedMode = "cast"
	} else if *forge {
		selectedMode = "forge"
	} else {
		// Default mode if neither is chosen
		printUsage()
		log.Fatal("No mode selected")
	}
	utils.Setup()
	log.Info("starting up...")
	configs, err := utils.LoadConfig("input/config.yaml")
	if err != nil {
		fmt.Printf("Failed to read config: %v", err)
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Debugf("Read config for : %+v", config.Name)
	}
	fmt.Print(utils.ForgeLogo)
	switch selectedMode {
	case "smelt":
		fmt.Println("Smelting")
		smelter.Smelt(configs)
	case "cast":
		fmt.Println("Casting")
		caster.Cast(configs)
	case "forge":
		fmt.Println("Forging")
		forger.Forge()

	}
	// utils.ResetTerminal()
}
