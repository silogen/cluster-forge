# ARGO Applications Usage Guide

This document provides a comprehensive guide for ARGO application maintenance.

## Table of Contents

- [Argo Overview](#workflow-overview)
- [Prerequisites](#prerequisites)
- [Detailed Usage Steps](#detailed-usage-steps)
  - [Gitea changes](#gitea-changes)
  - [ArgoCD Workflow](#argocd-workflow)


## Argo Overview

ArgoCD is a declarative, GitOps-based continuous delivery tool for Kubernetes
In order to apply changes on the K8 cluster, changes needs to be done on the git repository used as a reference for all changes. That component is Gitea

In case changes are needed for a current Argo App, then changes are needed just in the Gitea repo. Otherwise a new argo CD app is also needed

![alt text](img/argo-gitea.png "Argo/Gitea workflow")

## Prerequisites

Ensure the following tools are installed:

- **kubectl**

A functional Kubernetes cluster is required for deployment. The current KUBECONFIG context should point to the target cluster.

## Detailed Usage Steps

In order to apply changes in source code admin user needs first to do changes directly to Gitea project, so then changes are visible in the environment based on the ArgoCD workflow of the application

Thus, admin user can perform changes using WebUI for simple commit or just use an ephemeral container session to apply something more complicated

### Gitea changes

A. If changes are very simple, this can be the easy way to apply changes

1. Open https://gitea.K8-DOMAIN/

   Consider K8-DOMAIN with valid subdomain URL <br><br>

2. Login with valid credentials from secret "gitea-admin-credentials" in namespace "cf-gitea". Run the following to fetch the credentials

```bash
kubectl get secret gitea-admin-credentials -n cf-gitea -o go-template='{{range $k,$v := .data}}{{"### "}}{{$k}}{{"\n"}}{{$v|base64decode}}{{"\n\n"}}{{end}}'
```

3. Explore the source code and verify the argo apps there, just browse to:

https://gitea.K8-DOMAIN/cluster-org/cluster-forge/src/branch/main/root/values.yaml


Thosa file contains all Argo Apps in yaml format with a block like:

```yaml
cert-manager:
   path: cert-manager/v1.18.2
   namespace: cert-manager
   valuesFile: ../values_cf.yaml
   syncWave: -3
```

In this case app cert-manager is detailed with the path where manifests are located and namespace used for the app. Also the app name cert-manager must be included in enabledApps block in same values.yaml file
In this case, all changes needed for the app must be located at sources of cert-manager/v1.18.2. And the values_cf.yaml file will contain values that will overrride the default values.yaml that is expected at cert-manager/v1.18.2/values.yaml

If changes involve many different files, then it can be a good option to use an ephimeral pod to run an push changes to gitea using git protocol

```bash
1. Create a pod to do changes and apply changes. Jump into the container with a bash session:
kubectl run gitea-pr-tool --rm -it --image=ubuntu --restart=Never -n default -- bash

2. Install some needed packages
DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git ca-certificates curl

# 3. Clone the repo
export GITEA_USER=forge
export GITEA_TOKEN=clusterforge
cd /opt
git clone http://$GITEA_USER:$GITEA_TOKEN@gitea-http.cf-gitea.svc.cluster.local:3000/forge/clusterforge.git
cd clusterforge

# 4. (From localhost shell) Now considering you have some source code ready to be added as changes in localhost as ./my-changes.yaml
# Those changes can be uploaded from locahost to the pod doing:
kubectl cp ./my-changes.yaml default/gitea-pr-tool:/opt/clusterforge/my-changes.yaml

# 5. Move the changes to pproper foder if needed. When ready just apply changes
git config --global user.email "plat-team_do-not-reply@silogen.ai"
git config --global user.name "Platform Team"
git add *
git commit -m "Manual commit"
git push
```

### ArgoCD Workflow

Connect to ArgoCD to visualize the application that needs to be edited or created

1. Open https://argocd.K8-DOMAIN/

   Consider K8-DOMAIN with valid subdomain URL <br><br>

2. Use admin as username and then get password credentials from secret "argocd-initial-admin-secret" in namespace "argocd". Run the following to fetch the credentials below value "### password" line

```bash
  kubectl get secret argocd-initial-admin-secret -n argocd -o go-template='{{range $k,$v := .data}}{{"### "}}{{$k}}{{"\n"}}{{$v|base64decode}}{{"\n\n"}}{{end}}'
```

3. Open one argo App that requires to be edited and validate changes are sync to the sources folder
E.g. cert-manager will be visible at https://argocd.K8-DOMAIN/applications/argocd/cert-manager?view=tree&resource 

