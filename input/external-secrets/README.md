[External Secrets](https://external-secrets.io/latest/) is used to populate secrets into cluster without directly applying secrets. The cluster store backend can be (for example) AWS Secrets, Google Secrets Manager, 1Password, Vault, etc.
This default installation uses local kubernetes secrets as a backend to ensure applications are configured properly to use External Secrets. In non-demo/test use the backend must be switched to a production quality secure location.

## Background information
There are two cluster_secret_stores and one password object found after deploying external-secerts with k8s-cluster-secret-store
```
➜ kubectl get clustersecretstore

NAME                AGE     STATUS   CAPABILITIES   READY
fake-secret-store   3h10m   Valid    ReadWrite      True
k8s-secret-store    3h10m   Valid    ReadWrite      True

➜ kubectl get passwords -n cf-es-backend
NAME              AGE
tenant-password   3h25m
```
- "fake-secret-store" is for providing not random, but predefined secrets
(e.g., a tenant name) 
- "k8s-secret-store" is for patching secrets in "cf-es-backend" namespace to any namespaces 
- "tenant-password" password generator in "cf-es-backend"

## Example of creating external-secrets/k8s secrets in "cf-es-backend" namespace
To create a secret in "cf-es-backend" namespace, please see below.
```
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: config-env
  namespace: cf-es-backend 
spec:
  refreshInterval: "0"
  target:
    name: default-minio-tenant-env-configuration
    template:
      data:
        config.env: |
            export MINIO_SERVER_URL="https://minio.minio-tenant-default.svc.cluster.local:443"
            export MINIO_API_ROOT_ACCESS="on"
            export MINIO_ROOT_USER="minioroot"
            export MINIO_ROOT_PASSWORD="{{ .password }}"
  dataFrom:
  - sourceRef:
      generatorRef:
        apiVersion: generators.external-secrets.io/v1alpha1
        kind: Password
        name: "tenant-password"
```
This creates an external-secret using "tenant-password" generator in "cf-es-backend"
namespace. The created external-secret will create a k8s secret having name 
"default-minio-tenant-env-configuration". The value of refreshInterval is "0" 
not to have random secret every interval.

## Example of patching secrets from "cf-es-backend" namespace to any namespaces
To patch this secret in another namespace, please see below.
```
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: config-env
  namespace: minio-tenant-default
spec:
  refreshInterval: "0"
  secretStoreRef:
    name: k8s-secret-store
    kind: ClusterSecretStore
  target:
    name: default-minio-tenant-env-configuration
  data:
    - secretKey: config.env
      remoteRef:
        key: default-minio-tenant-env-configuration
        property: config.env
```
This creates an external-secret in "minio-tenant-default". The external-secert
creates a k8s secerts having name "default-minio-tenant-env-configuration".
- data[0].remoteRef.key points the name of a k8s secret in "cf-es-backend" namespace
- data[0].remoteRef.property points the name of key in the k8s secret
- data[0].secretKey defines the name of key in the k8s secret going be created 
by this external-secret
