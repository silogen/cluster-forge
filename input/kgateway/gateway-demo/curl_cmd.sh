# Apply the resources in this folder first
export INGRESS_GW_ADDRESS=$(kubectl get svc -n kgateway-system http -o=jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo $INGRESS_GW_ADDRESS
curl -i http://$INGRESS_GW_ADDRESS:8080/headers -H "host: www.example.com:8080"
