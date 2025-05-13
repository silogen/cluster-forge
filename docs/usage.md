# Cluster-Forge Usage Guide

This document provides a comprehensive guide for using Cluster-Forge to create and deploy Kubernetes stacks.

## Table of Contents

- [Workflow Overview](#workflow-overview)
- [Prerequisites](#prerequisites)
- [Detailed Usage Steps](#detailed-usage-steps)
  - [Step 0: Configure Tools](#step-0-configure-tools-optional)
  - [Step 1: Mine](#step-1-mine)
  - [Step 2: Smelt](#step-2-smelt)
  - [Step 3: Customize](#step-3-customize-optional)
  - [Step 4: Cast](#step-4-cast)
  - [Step 5: Forge (Combined Operation)](#step-5-forge-combined-operation)
- [Configuration Options](#configuration-options)
- [Common Use Cases](#common-use-cases)
- [Troubleshooting](#troubleshooting)

## Workflow Overview

Cluster-Forge operates through a sequence of well-defined steps:

1. **Mine**: Process input configuration to generate normalized YAML in the input directory
2. **Smelt**: Process input configuration to generate normalized YAML in the working directory
3. **Customize** (optional): Edit files in the working directory
4. **Cast**: Compile components into a deployable stack image
5. **Forge**: Combined operation that runs both smelt and cast, creating an ephemeral image

After completing these steps, the resulting stack can be deployed to a Kubernetes cluster.

## Prerequisites

Ensure the following tools are installed:

- **[Devbox](DEVBOX.md)** (recommended for development)
- **Docker** with multi-architecture support
  - Run `docker buildx create --name multiarch-builder --use` to enable multi-architecture builds
- **Golang** v1.23 or higher
- **kubectl**
- **Helm**

A functional Kubernetes cluster is required for deployment. The current KUBECONFIG context should point to the target cluster.

## Detailed Usage Steps

### Step 0: Configure Tools (Optional)

If you need to customize which components are included in your stack, edit the `input/config.yaml` file.

Example configuration:

```yaml
- name: monitoring-stack
  collection:
  - prometheus
  - grafana
  - grafana-loki

- name: prometheus
  namespace: "monitoring"
  manifestpath:
  - prometheus/manifests/sourced

- name: grafana
  namespace: "grafana"
  syncwave: 1
  manifestpath:
  - grafana/manifests/sourced

- name: grafana-loki
  namespace: "grafana-loki"
  syncwave: 1
  manifestpath:
  - grafana-loki/manifests/sourced
```

### Step 1: Mine

The `mine` command processes the input configuration and generates normalized YAML in the input directory. This step is used to update or configure the manifests that will be used by the `smelt` operation.

```sh
# Using Go command
go run . mine

# Using Devbox shorthand
mine
```

This command will:
1. Read the configuration from `input/config.yaml`
2. Process and normalize the YAML files
3. Update manifest files in the input directory

### Step 2: Smelt

The `smelt` step processes the input configuration and generates normalized YAML in the working directory.

```sh
# Using Go command
go run . smelt

# Using Devbox shorthand
smelt

# With debug logging
LOG_LEVEL=debug go run . smelt
just debug-smelt
```

This command will:
1. Read the configuration from the specified config file (default: `input/config.yaml`)
2. Process and normalize the YAML files
3. Generate output files in the `./working` directory

Command options:
```
--config, -c     Path to the config file (default: "input/config.yaml")
--non-interactive, -n  Non-interactive mode, fail if information is missing
--gitopsUrl      URL target for ArgoCD app (default: http://gitea-http.cf-gitea.svc:3000/forge/clusterforge.git)
--gitopsBranch   Branch for ArgoCD app (default: HEAD)
--gitopsPathPrefix  Prefix for ArgoCD app target path
```

### Step 3: Customize (Optional)

After the `smelt` step, you can customize the generated files in the `./working` directory before proceeding to the `cast` step. This is entirely optional but allows for tailoring the configuration to specific needs.

Common customizations include:
- Modifying resource limits and requests
- Adding labels or annotations to resources
- Adjusting ConfigMap values
- Updating image versions

### Step 4: Cast

The `cast` step compiles the components from the working directory into a deployable stack image.

```sh
# Using Go command
go run . cast

# Using Devbox shorthand
cast

# With debug logging
LOG_LEVEL=debug go run . cast
just debug-cast

# Specifying image name and stack name
go run . cast --imageName my-image --stackName my-stack
```

This command will:
1. Read the normalized YAML from the `./working` directory
2. Create a Docker image containing the stack components
3. Push the image to a registry (ephemeral by default, or specified registry)
4. Generate deployment scripts in the `./stacks/<stack-name>` directory

Command options:
```
--config, -c     Path to the config file (default: "input/config.yaml")
--non-interactive, -n  Non-interactive mode, fail if information is missing
--gitea, -g      How to deploy gitea (allowed values: internal, external-access, external, none)
--imageName, -i  Name of docker image to push (required with --stackName in non-interactive mode)
--stackName, -s  Name of stack (required with --imageName in non-interactive mode)
--private        If set to true, gitea image will not be public
--argocdui, -u   Deploy ArgoCD with UI
```

By default, an image is created and pushed to an ephemeral registry (ttl.sh) where it will be available for 12 hours. To push the image to a registry of your choice, set the environment variable `PUBLISH_IMAGE=true`.

### Step 5: Forge (Combined Operation)

The `forge` command combines the `smelt` and `cast` steps to create an ephemeral image with a single command.

```sh
# Using Go command
go run . forge

# Using Devbox shorthand
forge

# With debug logging
LOG_LEVEL=debug go run . forge
just debug-forge
```

This command is ideal for quick testing or development cycles as it combines multiple steps.

## Configuration Options

Cluster-Forge supports various configuration options through command-line flags, environment variables, and configuration files.

### Environment Variables

- `LOG_LEVEL`: Sets the logging level (debug, info, warn, error)
- `PUBLISH_IMAGE`: When set to "true", enables publishing to specified registry instead of ephemeral registry

### Configuration Files

- `input/config.yaml`: Main configuration file defining the components to include in the stack
- `options/defaults.yaml`: Default configuration values
- `release-configs/*.yaml`: Pre-defined configuration profiles for common scenarios

## Common Use Cases

### Deploying a Pre-built Stack

To deploy a released stack:
1. Download the stack from the GitHub releases page
2. Extract the package
3. Run the deploy script:
   ```sh
   ./deploy.sh
   ```

### Building a Custom Stack

To build a custom stack with specific components:
1. Edit `input/config.yaml` to include your desired components
2. Run the `forge` command:
   ```sh
   go run . forge
   ```
3. Deploy the generated stack:
   ```sh
   ./stacks/<stack-name>/deploy.sh
   ```

### Creating a Production-Ready Stack

For production deployments:
1. Edit `input/config.yaml` to include your desired components
2. Run the `smelt` command:
   ```sh
   go run . smelt
   ```
3. Customize the generated files in the `./working` directory
4. Run the `cast` command with a specific image and stack name:
   ```sh
   PUBLISH_IMAGE=true go run . cast --imageName my-registry/my-image:v1.0.0 --stackName my-prod-stack
   ```
5. Deploy the generated stack:
   ```sh
   ./stacks/my-prod-stack/deploy.sh
   ```

## Troubleshooting

### Terminal Line Handling Issues

If errors occur alongside the progress spinner, terminal formatting might be affected. To restore the terminal, run:
```sh
reset
```

### Build Errors

If you encounter errors during the `cast` process, ensure multi-architecture Docker builds are enabled:
```sh
docker buildx create --name multiarch-builder --use
```

### Deployment Failures

If the stack fails to deploy:
1. Check the logs of the failing components
2. Verify that the Kubernetes cluster meets the prerequisites
3. Ensure the KUBECONFIG context points to the correct cluster
4. Try the uninstall script and then redeploy:
   ```sh
   ./stacks/<stack-name>/uninstall.sh
   ./stacks/<stack-name>/deploy.sh
   ```

### Cleanup

To clean up your working environment:
```sh
# Using Devbox
devbox run clean

# Using justfile
just clean-all

# Manual cleanup
rm -rf ./working/*
rm -rf ./stacks/*
```