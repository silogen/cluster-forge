#!/bin/bash

kubectl create ns argocd
helm template --release-name argocd ./argocd/8.3.0 --namespace argocd | kubectl apply -f -
kubectl rollout status statefulset/argocd-application-controller -n argocd
kubectl rollout status deploy/argocd-applicationset-controller -n argocd
kubectl rollout status deploy/argocd-redis -n argocd
kubectl rollout status deploy/argocd-repo-server -n argocd
sleep 3
helm template ./cluster-forge | kubectl apply -f -
