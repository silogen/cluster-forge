#!/bin/bash
cd "$(dirname "$0")"

kubectl create ns cf-gitea
if [ -f gitea_pvc_init.yaml ]; then
    sleep 3
    kubectl apply -f gitea_pvc_init.yaml
    kubectl wait --for=condition=complete --timeout=30s job/gitea-init-job -n cf-gitea
fi
kubectl apply -f gitea.yaml
kubectl rollout status deploy/gitea -n cf-gitea

kubectl create ns argocd
bash ./generate-argocd-secret.sh
kubectl apply -n argocd -f argocd.yaml
if [ -f argocd2.yaml ]; then
    sleep 3
    kubectl apply -n argocd -f argocd2.yaml
fi
kubectl rollout status deploy/gitea -n cf-gitea
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl apply -f argoapp.yaml
