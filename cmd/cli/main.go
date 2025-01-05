/**
 * Copyright 2025 Advanced Micro Devices, Inc. All rights reserved.
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

	// "text/template"
	// log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

var (
	model string
	gpus  int
)

func printHelp(cmd *cobra.Command, args []string) {
	cmd.Help()
}

// Naming TBD
var rootCmd = &cobra.Command{
	Use:   "app",
	Short: "AI Workflow Orchestrator",
	Run:   printHelp,
}

var workload = &cobra.Command{
	Use:   "workloads",
	Short: "Workload operations",
	Run:   printHelp,
}

var deploy = &cobra.Command{
	Use:   "deploy",
	Short: "Deploy a workload",
	Long:  "Deploy a workload on Kubernetes via Cluster Forge",
	Run:   printHelp,
	// Run deploy flags validation before any deploy subcommand
	PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
		return validateDeployFlags()
	},
}

func validateDeployFlags() error {
	// Validate shared flags
	if model == "" {
		return fmt.Errorf("model is required")
	}

	if gpus <= 0 {
		return fmt.Errorf("the --gpus flag must be specified and greater than 0")
	}

	return nil
}

var deployInference = &cobra.Command{
	Use:   "inference",
	Short: "Deploy an inference workload",
	Run: func(cmd *cobra.Command, args []string) {
		runDeployInference(model, gpus)
	},
}

var deployTraining = &cobra.Command{
	Use:   "training",
	Short: "Deploy a training workload",
	PreRunE: func(cmd *cobra.Command, args []string) error {

		epochs, _ := cmd.Flags().GetInt("epochs")
		if epochs <= 0 {
			return fmt.Errorf("the --epochs flag must be provided and be greater than 0")
		}

		bucket, _ := cmd.Flags().GetString("bucket")
		if bucket == "" {
			return fmt.Errorf("the --bucket flag must be provided")
		}

		return nil
	},
	Run: func(cmd *cobra.Command, args []string) {
		lora, _ := cmd.Flags().GetBool("lora")
		epochs, _ := cmd.Flags().GetInt("epochs")
		bucket, _ := cmd.Flags().GetString("bucket")

		runDeployTraining(model, gpus, epochs, bucket, lora)
	},
}

func runDeployInference(model string, gpus int) {
	// TODO: Implement the actual deployment logic
	fmt.Printf("Deploying inference workload with model %s with %d GPUs\n", model, gpus)
}

func runDeployTraining(model string, gpus int, epochs int, bucket string, lora bool) {
	// TODO: Implement the actual deployment logic
	fmt.Printf("Deploying training workload with model %s with %d GPUs, %d epochs, bucket: %s, LoRa enabled: %t\n", model, gpus, epochs, bucket, lora)
}

func init() {
	deploy.PersistentFlags().StringVar(&model, "model", "", "Model to deploy")
	deploy.PersistentFlags().IntVar(&gpus, "gpus", 0, "Number of GPUs to use")

	deployTraining.Flags().Bool("lora", false, "Train as LoRA")
	deployTraining.Flags().Int("epochs", 0, "Number of epochs")
	deployTraining.Flags().String("bucket", "", "Bucket to fetch data from")

	deploy.MarkFlagRequired("model")
	deploy.MarkFlagRequired("gpus")
	deployTraining.MarkFlagRequired("epochs")
	deployTraining.MarkFlagRequired("bucket")

	rootCmd.AddCommand(workload)
	workload.AddCommand(deploy)
	deploy.AddCommand(deployInference)
	deploy.AddCommand(deployTraining)
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}
