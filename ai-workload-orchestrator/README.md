# AI Workload Orchestrator

## Description

- describe components and purpose of the AI Workload Orchestrator

## Installation

- describe how to install the AI Workload Orchestrator (Cluster-Forge or applying manifests)
- remember to mention that manifests for operators are in input/ directory
- Ray operator
- Kueue operator
- Kueue resource flavour(s)
- Kueue Cluster Queue
- Kueue Local Queue

## Usage

- describe how to use the AI Workload Orchestrator
- describe example multi-node workloads
  - Distributed pretraining/finetuning (SFT), latter with LORA
  - Distributed inference with VLLM (tensor/pipeline parallel)
  - Distributed DPO
- Multi-node workloads become single-node by adjustting GPU requests (notice also changes to VLLM pipeline parallel) 