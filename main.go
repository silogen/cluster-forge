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

	"github.com/silogen/cluster-forge/cmd/menu"
	"github.com/silogen/cluster-forge/cmd/utils"
	log "github.com/sirupsen/logrus"
)

func printUsage() {
	fmt.Println(`Usage:
    Pending...`)
}

func main() {
	utils.Setup()
	log.Info("starting up...")
	configs, err := utils.LoadConfig("config.yaml")
	if err != nil {
		log.Fatalf("Failed to read config: %v", err)
	}
	for _, config := range configs {
		log.Debugf("Read config for : %+v", config.Name)
	}

	menu.Menu(configs)

}
