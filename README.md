# cluster-forge
Kuberentes operator which sets up all platform tools to have a cluster ready for applications to run.

## Overview
Cluster-Forge is a tool used to includes various components based on 3rd party/community tools or components along with in-house deployments into a single stack (packaged set of ready components) to be deployed in a kubernetes cluster.

This is not necessarily meant to replace 'helm install' and 'kubectl apply' for a single use dev cluster. It is meant to wrap all those together for the use of repeated kubernetes cluster deployments. Test clusters, ephemeral pipeline clusters, or just scaling multiple clusters.

It is designed with the idea of 'ephemeral clusters' and easily reproducable clusters in mind.

## Usage
Ensure golang v1.23, kubectl, and helm are installed. For convenience, it can also be run with docker.

To create a package, there are 3 (or up to 5 depending on how we count) steps.

### Step 0
If the tool needed is not already included, add it to input/config.yaml

### Step 1 (SMELT)
Run 'smelt', which will generate formatted (yaml) configs which will be used.
```sh
go run . --smelt
```

Or alternatively with Docker

```sh
alias xforge="docker compose run forge"
xforge --smelt
```




![Smest Demo](docs/demoSmelt.gif)


Select the components to include and they will be generated.

### Step 1.5 (optional)
Add any customizations needed to files in /working
Likely not needed, and instructions to come here.

### Step 2 (CAST)
Compile the components into a stack

```sh
go run . --cast
```


![Cast Demo](docs/demoCast.gif)

### Step 3 (FORGE)
This step deploys a stack to a cluster
```sh
go run . --forge
```
