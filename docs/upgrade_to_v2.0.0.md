# Upgrade Guide: to v2.0.0

> ⚠️ **Important Disclaimers**
> - The helper script referenced below is an **example script only**; adjust paths and commands as needed for your system.
> - This is for illustration purposes only and **not officially supported.**
> - Always test upgrade procedures in a safe environment before relying on them in production.
> - The upgrade process is **not guaranteed to be backwards compatible between two arbitrary versions.**

## Overview

This guide covers the migration to cluster-forge **v2.0.0**. The upgrade involves:

- Exporting AIRM CNPG database and RabbitMQ data before removing affected applications
- Disabling ArgoCD auto-sync and deleting deprecated applications (`aim-cluster-model-source`, `kaiwo`, `kaiwo-crds`, `kaiwo-config`, `airm`, `aiwb`)
- Removing deprecated CRDs (`aimclustermodel`, `aimclustermodelsource`, `aimclusterservicetemplates`)
- Updating `global.targetRevision` to `v2.0.0` in your Gitea `cluster-values/values.yaml`
- Re-importing AIRM database and RabbitMQ data after the new `airm-infra-components` app is healthy
- Redeploying AIRM with the restored data
- Updating Keycloak redirect URIs for AIWorkbench

## Helper Script

A helper script is provided to automate the data export, ArgoCD cleanup, and to print the remaining manual steps:

```
scripts/utils/upgrade_2.0.0.sh
```

See [scripts/utils/README.md](../scripts/utils/README.md) for the full list of utility scripts and further context.

### What the script does

1. Exports AIRM CNPG database data to `/tmp/backups/` via `export_databases.sh`
2. Exports RabbitMQ data to `/tmp/backups/` via `export_rabbitmq.sh`
3. Logs into the ArgoCD server and disables auto-sync on `cluster-forge`
4. Disables auto-sync and cascade-deletes: `aim-cluster-model-source`, `kaiwo`, `kaiwo-crds`, `kaiwo-config`, `airm`, `aiwb`
5. Waits for all deleted applications to be fully removed (15-minute timeout)
6. Deletes all `aimclustermodel`, `aimclustermodelsource`, and `aimclusterservicetemplates` resources cluster-wide
7. Deletes AIRM secrets that will be recreated by the new application version
8. Prints the remaining manual steps (see below)

### Running the script

```bash
cd scripts/utils
./upgrade_2.0.0.sh
```

> **Note:** You may need to manually remove finalizers from stuck resources in the `airm` namespace before the wait step completes. The script will print the relevant `kubectl patch` command.

## Manual Steps After the Script

### Gitea — `cluster-values/values.yaml`

- Ensure your enabled apps list is in sync with `root/<size>_values.yaml` for your `global.clusterSize`
- Comment out `airm` from the enabled apps list (to create a window for importing data)
- Set `global.targetRevision` to `v2.0.0` (or a release candidate tag)
- Add `helmParameters` for `airm` and `aiwb` if installing a release candidate

### ArgoCD Web UI

- Update the `cluster-forge` parent app source to match `global.targetRevision`
- Re-enable auto-sync on `cluster-forge` (disabled by the script)
- Refresh the `cluster-forge` app
- Wait for `airm-infra-components` to be **healthy and synced** before proceeding

### Shell — Restore Data

```bash
scripts/utils/import_databases.sh "<path-to-airm-db-export-file>"
scripts/utils/import_rabbitmq.sh  "<path-to-rmq-export-file>"
```

The export file paths are printed by the script when it runs.

### Gitea — Re-enable AIRM

- Uncomment `airm` in the enabled apps list to redeploy AIRM with the restored data

### ArgoCD Web UI

- Sync `cluster-forge` to deploy AIRM with the restored data

### Keycloak

- Log into `https://kc.<domain>` as `silogen-admin` (password from secret `keycloak/keycloak-credentials`)
- Switch to the **AIRM** realm
- Click **Clients** and edit the first entry (`354a0fa1-35ac-4a6d-9c4d-d661129c2cd0`)
- Add the following valid redirect URIs:
  - `https://aiwbapi.<domain>/*`
  - `https://aiwbui.<domain>/*`

### Validate

- Log into `https://airmui.<domain>` as `devuser@<domain>` (password from secret `airm/airm-user-credentials`)
- Log into `https://aiwbui.<domain>`
