# Cluster-Forge

**A helper tool that sets up all essential platform tools to prepare a Kubernetes cluster for running applications.**

[Overview](#overview)<br>
[Usage](#usage)<br>
[Storage Classes](#storage-classes)<br>
[Database Backup & Restore]()<br>
[Known Issues](#known-issues)<br>
[Future Improvements](#future-improvements)<br>
[Conclusion](#conclusion)<br>

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

## Storage Classes
Storage classes are provided by default with Longhorn. These can be changed or customized as needed.

Out of the box, these are the storage classes and purposes:

| Purpose                      | storageclass | Type | Locality     |     |
| ---------------------------- | ------------ | ---- | ------------ | --- |
| GPU Job                      | mlstorage    | RWO  | LOCAL/remote |     |
| GPU Job                      | default      | RWO  | LOCAL/remote |     |
| Ask / know what you're doing | direct       | RWO  | LOCAL        |     |
| Multi-container              | multinode    | RWX  | ANYWHERE     |     |

## Database Backup & Restore
AIRM and Keycloak are two components which use Cloud Native Postgresql (CNPG) for data persistence. There are two backup paths documented here, the presently used method via the pg_dump and psql binaries, and a pending, but soon to be preferred, on-demand method.

  1. <b>pg_dump utility with psql client for restoration:</b><br>
  - this example uses AIRM, but process is essentially the same for Keycloak:
  - use k9s or kubectl to forward port 5432 of a running CNPG pod
    - `kubectl port-forward -n airm pod/$(kubectl get pods -n airm | grep -P "airm-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432`
    - verify port forward is active: `ps -f | grep 'kubectl' | grep 'port-forward'`
  - find the secret `airm-cnpg-user` in namespace `airm` and decode the `password` key
  - check for compatible pg_dump and pgsql binaries / Docker image on localhost
  - if not present, install (example here for Debian/Ubuntu):
    ```
      wget https://www.postgresql.org/media/keys/ACCC4CF8.asc
      sudo apt-key add ACCC4CF8.asc
      echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
      sudo apt-get update
      sudo apt-get install postgresql-17 postgresql-client-17
    ```
  - run backup command from your local machine: `pg_dump -h 127.0.0.1 -U airm_user airm > /tmp/airm-<cluserName>-$(date +%Y-%m-%d).sql`
  - enter password for previously decoded airm_user
  - perform needed operation, and after done, delete the CNPG cluster and wait for all pods to be removed
  - wait for at least one cnpg pod to come up and again (triggered by Argo CD) and forward port 5432
  - if an existing db is there with tables, you need to drop it first:
      - open shell to the AIRM CNPG pod (primary)
      - `psql -U airm`
      - `DROP DATABASE airm WITH (FORCE);`
      - `CREATE DATABASE airm OWNER airm_user ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;`
      - `GRANT CREATE ON SCHEMA public TO airm_user;`
  - run the restoration: `psql -h 127.0.0.1 -U airm_user airm < /tmp/airm-<clusterName>-<date>.sql` using the same airm_user secret as before
  - restart airm api & ui pods

  2. <b>on-demand CNPG Backup</b>: this method leverages CNPG cluster.spec.backup specification and will become the preferred path after the process has been validated

      - sample manifest:

  ```
    # on-demand-backup.yaml
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: on-demand
      namespace: airm
    spec:
      cluster:
        name: airm-cnpg
      method: barmanObjectStore
      target: prefer-standby
  ```

  - `kubectl apply -f on-demand-backup.yaml`
  - check the Backup object in the cluster, which will update the top-level `Status` section as it progresses.

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
