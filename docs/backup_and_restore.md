# AMD Enterprise AI Suite - Backup and Restore Procedures

  1. Database Backup & Restore
  2. RabbitMQ Backup & Restore

## 1. Database Backup & Restore

AIRM and Keycloak are two components which use Cloud Native Postgresql (CNPG) for data persistence. Follow this procedure to backup and restore the databases.

  1. Backup:
  
This method uses the **pg_dump** utility:
```
     # Gather credentials:find the secret `airm-cnpg-user` in namespace `airm` and decode the `password` key
     # use k9s or kubectl to forward port 5432 of a running CNPG pod

     # AIRM example:
    kubectl port-forward -n airm pod/$(kubectl get pods -n airm | grep -P "airm-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5432:5432

    # Keycloak example (*note: mapping to local port 5433 to avoid conflict with AIRM CNPG*):
     kubectl port-forward -n keycloak pod/$(kubectl get pods -n keycloak | grep -P "keycloak-cnpg-\d" | head -1 | sed 's/^\([^[:space:]]*\).*$/\1/') 5433:5432

     - verify port forward is active: `ps -f | grep 'kubectl' | grep 'port-forward'`
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
```

## RabbitMQ Backup & Restore

### I. Backup:
  
  **defintions & queue messages:**
  ```
  # Stop RabbitMQ
  sudo systemctl stop rabbitmq-server
  
  # Create a backup of the RabbitMQ data directory
  sudo tar -cvf rabbitmq-backup.tar /var/lib/rabbitmq/mnesia
  
  # Start RabbitMQ (or skip if immediately proceeding to restore):
  sudo systemctl start rabbitmq-server
  ```
  **defintions only:**
  ```
  # Scope: Defintions only:

  rabbitmqctl export_definitions /path/to/backup_definitions.json
  ```
### II. Restore:
**defintions & queue messages:**
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
**defintions only:**
```
rabbitmqctl import_definitions /path/to/backup_definitions.json
```