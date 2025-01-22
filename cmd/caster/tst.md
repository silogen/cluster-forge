ttl.sh/ea80757c-c732-4127-94c3-8aa29a40be23:12h 







k apply -f gitea.yaml
k create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.3/manifests/core-install.yaml
k apply -f argo.yaml
