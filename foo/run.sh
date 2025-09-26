# Cleanup previous things
kubectl delete -f manifests.yaml

kubectl delete -f ../input/openbao/manifests/sourced/
kubectl delete pvc data-openbao-0 -n openbao


kubectl apply -f ../input/openbao/manifests/sourced/ --validate=false

sleep 8

kubectl exec -it openbao-0 -n openbao -- bao operator init -format=json -key-shares=1 -key-threshold=1 > /tmp/bao-keys.json

kubectl exec -it openbao-0 -n openbao -- bao operator unseal $(cat /tmp/bao-keys.json | jq -r '.unseal_keys_b64[0]')
kubectl exec -it openbao-0 -n openbao -- bao login $(cat /tmp/bao-keys.json | jq -r '.root_token')

cat /tmp/bao-keys.json | jq -r '.root_token'

kubectl exec -it openbao-0 -n openbao -- bao secrets enable -version=2 kv
kubectl exec -it openbao-0 -n openbao -- bao kv put kv/scripted scripted-bar=scripted-baz
sleep 1
kubectl exec -it openbao-0 -n openbao -- bao kv get kv/scripted

kubectl create clusterrolebinding oidc-reviewer  \
   --clusterrole=system:service-account-issuer-discovery \
   --group=system:unauthenticated

kubectl cp ./policy.hcl openbao-0:/tmp/policy.hcl -n openbao

kubectl exec openbao-0 -n openbao -- bao policy write star /tmp/policy.hcl

kubectl exec openbao-0 -n openbao -- bao auth enable jwt
kubectl exec openbao-0 -n openbao -- bao write auth/jwt/config \
   oidc_discovery_url=https://kubernetes.default.svc.cluster.local \
   oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

kubectl exec openbao-0 -n openbao -- bao write auth/jwt/role/vault-jwt-role \
   role_type="jwt" \
   bound_audiences='fooboundaudience' \
   user_claim="sub" \
   bound_subject="system:serviceaccount:openbao:openbao-test" \
   policies="star" \
   ttl="1h"

kubectl apply -f manifests.yaml

kubectl exec openbao-0 -n openbao -- bao auth enable userpass
kubectl exec openbao-0 -n openbao -- bao write auth/userpass/users/admin password="admin" policies="star"
