#!/bin/bash

kubectl create ns argocd
helm template --release-name argo-cd ./argo-cd/8.3.0 --namespace argocd | kubectl apply -f -
kubectl rollout status statefulset/argo-cd-argocd-application-controller -n argocd
kubectl rollout status deploy/argo-cd-argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argo-cd-argocd-redis -n argocd
kubectl rollout status deploy/argo-cd-argocd-repo-server -n argocd

helm template ./cluster-forge | kubectl apply -f -
