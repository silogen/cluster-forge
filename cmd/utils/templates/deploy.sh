#!/bin/bash
cd "$(dirname "$0")"
kubectl create ns argocd
kubectl apply -n argocd -f argocd.yaml
kubectl apply -f gitea.yaml
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