# Pluggable Storage Classes

It is required that your cluster has either:

- A storage class named 'default'

OR

- Set the name of your desired default storage class via following helm template overrides:

Override example snippets:

```shell
# Keycloak (mandatory component)
helm template keycloak ... \
  --set storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
  ...

# AIWB CNPG (pluggable / optional component)
helm template aiwb-infra-cnpg ... \
  --set storage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
  --set walStorage.storageClass=${DEFAULT_STORAGE_CLASS_NAME} \
...

# SeaweedFS (pluggable / optional component)
helm template seaweedfs-config ... \
  --set seaweed.storageClassName=${DEFAULT_STORAGE_CLASS_NAME} \
  ...
```
