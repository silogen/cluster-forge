# Workflow Steps

Cluster-Forge operates through a sequence of well-defined steps:

1. **(Optional)** Update `input/config.yaml` with any required tools or configurations.  
2. **Smelt**: Normalize YAML configurations.  
3. **Customize**: Add optional template-based customizations.  
4. **Cast**: Package the software stack into a deployable image.  
5. **Temper**: Verify cluster readiness for the Forge step.  
6. **Forge**: Deploy the image and start up the software stack in your cluster.  

**NOTES**: 

1. The casted SW stack can also be deployed with a shell script (deploy.sh) found in stacks/\<stackname\> directory.
2. An uninstall script is also found the the same directory which should uninstall tools installed by a stack deployment; forged crossplane objects will remain on your cluster for subsequent deployments. 
3. A helper script for cleaning your smelts and casts is available scripts/clean.sh

---

## Prerequisites

Ensure the following tools are installed:

- **[Devbox](docs/DEVBOX.md)** 
- **docker**
- **multi-architecture Docker builds**
  - run `docker buildx create --name multiarch-builder --use`

> **Important:**  
> If you don't use devbox, some commands in docs may not work directly. The steps will still work, but aliases and helper scripts won't be available. 
> Additionally, the following must also be installed:
> - **Golang** (v1.23 or higher)  
> - **kubectl**  
> - **Helm**  


## [Usage](docs/usage.md)

To deploy a released stack, download from the GitHub releases page, extract, and run deploy.sh.

For ease of testing ClusterForge compnents, the command ```forge``` run inside a devbox shell will run a smelt step, and immediately run cast, publishing an ephemeral image as described in [Usage](docs/usage.md).

To create a stack without the forge command, or for further instructions and options, see [Usage](docs/usage.md).


---
## Instruction of deploying monitoring tools
- [OpenObserve](input/openobserve/README.md)
- [Prometheus-Operator](input/kube-prometheus-stack/README.md)
- [otel-lgtm-stack](input/otel-lgtm-stack/README.md)

## Instruction of other tools
- [k8s-cluster-secret-store](input/k8s-cluster-secret-store/README.md)


## Usage

The process of creating and deploying a stack involves 3 to 5 steps depending on your use case.

---

### Step 0: Configure Tools (Optional)

If a required tool or component is missing, add it to the `input/config.yaml` file.

---

### Step 1: Smelt

The `smelt` step normalizes YAML configurations for the selected components.

Run the following command:

```sh
go run . smelt
```
or if using Devbox
```sh
smelt
```

This will generate formatted YAML configs based on your selections.


---

### Step 2: Customize (Optional)

To tailor your configuration, edit files under the `/working` directory.  
This step is optional.

---

### Step 3: Cast

The `cast` step compiles the components into a deployable stack image. By default, an image is created and pushed to an [ephemeral registry](ttl.sh) where it will be available for 12 hours. 

To push the image instead to a registry of your choice, set env variable PUBLISH_IMAGE=true and you will be given the option to specify the registry, image name and tag. 

Run the following command:

```sh
go run . cast
```
or if using Devbox
```sh
cast
```

> **Important:**  
> If you encounter build errors during the `cast` process, you may need to enable **multi-architecture Docker builds** with the following command:
> ```sh
> docker buildx create --name multiarch-builder --use
> ```


---

### Step 4: Temper

**(Work in Progress)**  

