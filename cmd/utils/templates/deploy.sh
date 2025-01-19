#!/bin/bash
kubectl create ns argocd
kubectl apply -f argocd.yaml
kubectl apply -f gitea.yaml
sleep 30
kubectl apply -f argoapp.yaml