# ClusterSecretStore having k8s secrets backend
This could be a handy way to show a simple demo like showing grafana-loki and minio-tenant together without setting external password backend.

- Namespace "cf-es-backend" stores all the secrets created by password generator.
- Then other tools, for example, minio-tenant is able to read secrets from "cf-es-backend"  namespace and create secrets inside of its own namespace
- The following steps are required who wants to handle secrets with "cf-es-backend" 
  - Create external-secrets in "cf-es-backend"
```
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: config-env
  namespace: cf-es-backend 
spec:
  refreshInterval: "30m"
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
  - Read external-secrets
```
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: config-env
  namespace: minio-tenant-default
spec:
  refreshInterval: "30m"
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
