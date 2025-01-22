#!/bin/bash
kubectl create ns argocd
kubectl apply -n argocd -f argocd.yaml
kubectl apply -f gitea.yaml
sleep 60
kubectl apply -f argoapp.yaml