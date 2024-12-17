# Cluster-Forge

**A Kubernetes operator that sets up all essential platform tools to prepare a cluster for running applications.**

## Overview

**Cluster-Forge** is a tool designed to bundle various third-party, community, and in-house components into a single, streamlined stack that can be deployed in Kubernetes clusters. By automating the process, Cluster-Forge simplifies the repeated creation of consistent, ready-to-use clusters.

This tool is not meant to replace simple `helm install` or `kubectl apply` commands for single-use development clusters. Instead, it wraps these workflows into a robust process tailored for scenarios such as:

- **Ephemeral test clusters**  
- **CI/CD pipeline clusters**  
- **Scaling and managing multiple clusters efficiently**

Cluster-Forge is built with the idea of **ephemeral and reproducible clusters**, enabling you to spin up identical environments quickly and reliably.

### Workflow Steps

Cluster-Forge operates through a sequence of well-defined steps:

1. **(Optional)** Update `input/config.yaml` with any required tools or configurations.  
2. **Smelt**: Normalize YAML configurations.  
3. **Customize**: Add optional template-based customizations.  
4. **Cast**: Package the software stack into a deployable image.  
5. **Temper**: Verify cluster readiness for the Forge step.  
6. **Forge**: Deploy the image and start up the software stack in your cluster.  

---

## Prerequisites

Ensure the following tools are installed:

- **Golang** (v1.23 or higher)  
- **kubectl**  
- **Helm**  

For added convenience, Cluster-Forge can also run with Docker.

---

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

This will generate formatted YAML configs based on your selections.

![Smelt Demo](docs/demoSmelt.gif)

---

### Step 2: Customize (Optional)

To tailor your configuration, edit files under the `/working` directory.  
While this step is optional for basic testing, it is essential to unlock the full benefits of Cluster-Forge. Detailed instructions will be provided in a future release.

---

### Step 3: Cast

The `cast` step compiles the components into a deployable stack image.

Run the following command:

```sh
go run . cast
```

> **Important:**  
> If you encounter build errors during the `cast` process, you may need to enable **multi-architecture Docker builds** with the following command:
> ```sh
> docker buildx create --name multiarch-builder --use
> ```

![Cast Demo](docs/demoCast.gif)

---

### Step 4: Temper

**(Work in Progress)**  

This step ensures critical resources are available in the target environment, including:

- A storage class  
- An external-secrets backend  
- S3-compatible bucket storage  

If any of these components are unavailable, Cluster-Forge will identify the gaps and allow you to make tradeoff decisions as needed. More instructions for this step will be added in future releases.

---

### Step 5: Forge

The `forge` step deploys the compiled stack to your Kubernetes cluster.

Run the following command:

```sh
go run . forge
```

---

## Known Issues

Cluster-Forge is still a work in progress, and the following issues are currently known:

1. **Kyverno Policies**: There are known issues when smelting Kyverno configurations. Avoid using Kyverno policies for now.  
2. **Size Limitations**: Selecting "all" components may exceed configuration limits and cause failures. A reasonable subset should work fine.  
3. **Terminal Line Handling**: Errors occurring alongside the progress spinner may cause terminal formatting issues. To restore the terminal, run:  
   ```sh
   reset
   ```

---

## Future Improvements

We are actively working on resolving the known issues and improving the overall functionality of Cluster-Forge. Your feedback is always welcome!

---

## Conclusion

Cluster-Forge is designed to simplify Kubernetes cluster management, especially when dealing with ephemeral, test, or pipeline clusters. By combining multiple tools and workflows into a repeatable process, Cluster-Forge saves time and ensures consistency across deployments.

Give it a try, and let us know how it works for you!
