Connection to console
```
kubectl port-forward -n minio-tenant-default svc/default-minio-tenant-console 9443:9443
```
Go to https://localhost:9443 in browser

username: default-user

password:
```
kubectl -n minio-tenant-default get secrets/default-user --template={{.data.CONSOLE_SECRET_KEY}} | base64 -d
```

api-access-key:
```
kubectl -n minio-tenant-default get secrets/default-user --template={{.data.API_ACCESS_KEY}} | base64 -d
```

api-secret-key:
```
kubectl -n minio-tenant-default get secrets/default-user --template={{.data.API_SECRET_KEY}} | base64 -d
```


Four buckets are going to be created as default at the moment
- default-bucket
- cluster-forge-loki
- cluster-forge-mimir
- cluster-forge-tempo
