# Cleanup previous things
bao operator init -format=json -key-shares=1 -key-threshold=1 > /tmp/bao-keys.json

bao operator unseal $(cat /tmp/bao-keys.json|grep -A1 unseal_keys_b64|tail -n 1|cut -d '"' -f 2)
bao login $(cat /tmp/bao-keys.json|grep root_token|cut -d '"' -f 4)

cat /tmp/bao-keys.json | jq -r '.root_token'

bao secrets enable -version=2 kv
bao kv put kv/scripted scripted-bar=scripted-baz
sleep 1
bao kv get kv/scripted


kubectl create clusterrolebinding oidc-reviewer  \
   --clusterrole=system:service-account-issuer-discovery \
   --group=system:unauthenticated

# Create policy.hcl
cat > /tmp/policy.hcl << EOF
path "*" {
  capabilities = ["sudo", "read", "list", "create", "update", "delete", "patch"]
}
EOF

kubectl cp ./policy.hcl openbao-0:/tmp/policy.hcl -n openbao

bao policy write star /tmp/policy.hcl

bao auth enable jwt
bao write auth/jwt/config  oidc_discovery_url=https://kubernetes.default.svc.cluster.local   oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

bao write auth/jwt/role/vault-jwt-role \
   role_type="jwt" \
   bound_audiences='clusterforge' \
   user_claim="sub" \
   bound_subject="system:serviceaccount:openbao:openbao-test" \
   policies="star" \
   ttl="1h"

kubectl apply -f manifests.yaml

bao auth enable userpass
bao write auth/userpass/users/admin password="admin" policies="star"

---
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
data:
  token: cy5YVU9iYmFzUDBQNlZWYll0eUZXYkZzdksK # "root"
