### DETAILS

Testing in app-dev-1 cluster and following these commands, an admin user should be able to setup 

### STEPS

1. Create go files first
```
go mod init grpc-authz-adapter
go mod tidy
```

2. Use those to create a docker image
```
docker build -t ghcr.io/silogen/grpc-authz-adapter:v0.1 .
docker push ghcr.io/silogen/grpc-authz-adapter:v0.1

docker build -t ttl.sh/grpc-authz-adapter-v0.0.1:24h .
docker push ttl.sh/grpc-authz-adapter-v0.0.1:24h
```

3. Add following URI as a valid redirect_uri for client app used in airm keycloak realm:

```
https://workspaces.app-dev.silogen.ai/*
```
