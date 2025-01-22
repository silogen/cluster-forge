# Cluster-Forge

**A helper tool that sets up all essential platform tools to prepare a Kubernetes cluster for running applications.**

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

**NOTES**: 

1. The casted SW stack can also be deployed with a shell script (deploy.sh) found in stacks/\<stackname\> directory.
2. An uninstall script is also found the the same directory which should uninstall tools installed by a stack deployment; forged crossplane objects will remain on your cluster for subsequent deployments. 
3. A helper script for cleaning your smelts and casts is available scripts/clean.sh

---

## Prerequisites

Ensure the following tools are installed:

- **Golang** (v1.23 or higher)  
- **kubectl**  
- **Helm**  
- **docker**
- **multi-architecture Docker builds**
  - run `docker buildx create --name multiarch-builder --use`



[Usage](docs/usage.md)


---
## Instruction of deploying monitoring tools
- [OpenObserve](input/openobserve/README.md)
- [Prometheus-Operator](input/kube-prometheus-stack/README.md)

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
