# AMD Enterprise AI Suite Maintenance

This document provides some useful steps/scripts to maintain your k8s cluster with AMD Enterprise AI Suite.

## Database Backup & Restore

AIRM and Keycloak are two components which use Cloud Native Postgresql (CNPG) for data persistence. There are two backup paths documented here, the presently used method via the pg_dump and psql binaries, and a pending, but soon to be preferred, on-demand method.

  1. **pg_dump utility with psql client for restoration** (this example uses AIRM, but process is essentially the same for Keycloak):
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
     - run backup command from your local machine: `pg_dump --clean -h 127.0.0.1 -U airm_user airm > /tmp/airm-<cluserName>-$(date +%Y-%m-%d).sql`
     - enter password for previously decoded airm_user
     - perform needed operation, e.g. delete the CNPG cluster and wait for all pods to get deleted
     - wait for atleast one cnpg pod to come up and again (triggered by Argo CD) and forward port 5432
     - run the restoration: `psql -h 127.0.0.1 -U airm_user airm < /tmp/airm-<clusterName>-<date>.sql` using the same airm_user secret as before
     - restart airm api & ui pods

  2. **on-demand CNPG Backup** (this method leverages CNPG cluster.spec.backup specification and will become the preferred path after the process has been validated):
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
     - this method is presently failing during the `walArchivingFailing` phase, and requires an update to the `Cluster` `.backup` definition

## RabbitMQ Backup & Restore

### I. Backup:

Scope includes definitions (schema of queues, exchanges, and bindings, as well as users, vhosts, and policies), and messages in the queues.
  
  ```
  # Stop RabbitMQ
  sudo systemctl stop rabbitmq-server
  
  # Create a backup of the RabbitMQ data directory
  sudo tar -cvf rabbitmq-backup.tar /var/lib/rabbitmq/mnesia
  
  # Start RabbitMQ (or skip if immediately proceeding to restore):
  sudo systemctl start rabbitmq-server
  ```

### II. Restore:

```
# Stop RabbitMQ:
sudo systemctl stop rabbitmq-server

# Remove default Mnesia directory:
sudo rm -rf /var/lib/rabbitmq/mnesia 

# Restore the RabbitMQ data directory from the backup:
sudo tar -xvf rabbitmq-backup.tar -C /

# Fix ownershiop of the restored files:
sudo chown -R rabbitmq:rabbitmq /var/lib/rabbitmq

# Start RabbitMQ:
sudo systemctl start rabbitmq-server
```