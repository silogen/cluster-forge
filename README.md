# Cluster-Forge

**A helper tool that sets up all essential platform tools to prepare a Kubernetes cluster for running applications.**

## Overview

**Cluster-Forge** is a tool designed to bundle various third-party, community, and in-house components into a single, streamlined stack that can be deployed in Kubernetes clusters. By automating the process, Cluster-Forge simplifies the repeated creation of consistent, ready-to-use clusters.

This tool is not meant to replace simple `helm install` or `kubectl apply` commands for single-use development clusters. Instead, it wraps these workflows into a robust process tailored for scenarios such as:

- **Ephemeral test clusters**  
- **CI/CD pipeline clusters**  
- **Scaling and managing multiple clusters efficiently**

Cluster-Forge is built with the idea of **ephemeral and reproducible clusters**, enabling you to spin up identical environments quickly and reliably.

## Usage
To deploy a ClusterForge SW stack, download a release package, and run 'deploy.sh'. This assumes there is a working kubernetes cluster to deploy into, and the current KUBECONFIG context refers to that cluster. 

While ClusterForge does not in any way require AMD Instinct GPU's, this was a primary use case during intial development. 
For ease of use in such a server, a helper script is available to deploy RKE2 kubernetes, install rocm, and then setup ClusterForge. It can be found in the setup.sh file. It can also be run with:
```bash
wget https://github.com/silogen/cluster-forge/blob/main/setup.sh | sudo bash
```

## Known Issues

Cluster-Forge is still a work in progress, and the following issues are currently known:

1. **Terminal Line Handling**: Errors occurring alongside the progress spinner may cause terminal formatting issues. To restore the terminal, run:  
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
