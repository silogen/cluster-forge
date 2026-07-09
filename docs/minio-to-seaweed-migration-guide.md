# Minio to SeaweedFS Migration Guide

**Estimated Time:** 20-30 minutes  
**Complexity:** Medium (3 manual steps)  
**Risk Level:** Medium (Data loss possible if not done correctly)

## Overview

This guide helps cluster managers migrate from minio s3 to seaweedfs s3 by upgrading cluster-forge from v2.1.3 to v2.2.0. The migration involves only **2 manual steps** and takes approximately **20-30 minutes**.

> **Important:** This migration will briefly affect access to s3 data. Plan accordingly and notify your team.

## Prerequisites

Before starting, verify your cluster meets these requirements:

```bash
  kubectl -n minio-tenant-default get pods
  kubectl -n minio-operator get pods
```

We should have 1 or more healthy pods named minio-operator-**** and one or more healthy pods named default-minio-tenant-pool-****. 

**Required Access:**
- kubectl admin permissions
- ArgoCD web UI access
- Gitea web UI access
- Current cluster-forge version v2.1.3

## Migration Process

### Step 1: Upgrade cluster-forge

**Navigate to Gitea:**
1. Open your browser and go to `https://gitea.<your-domain>`
2. Login with your credentials
3. Navigate to the `cluster-org/cluster-values` repository
4. Open the file: `values.yaml`
5. Click the **"Edit"** button (pencil icon)

**Make the following changes:**

**Change 1: Update targetRevision**

Find:
```yaml
targetRevision: v2.1.3
```

Change to:
```yaml
targetRevision: v2.2.0
```

**Change 2: Update enabledApps list**

In the `enabledApps:` section:

**Comment out** these apps (add `#` at the beginning):
```yaml
enabledApps:
  # - minio-operator
  # - minio-tenant
  # - minio-tenant-config
```

**Add** these new apps:
```yaml
enabledApps:
  - seaweedfs-crds
  - seaweedfs-operator
  - seaweedfs-config  
```

**Complete example:**
```yaml
targetRevision: v2.2.0

enabledApps:
  # Old gateway apps (commented out for migration)
  # - minio-operator
  # - minio-tenant
  # - minio-tenant-config

  # New gateway apps
  - seaweedfs-crds
  - seaweedfs-operator
  - seaweedfs-config

  # Other apps (unchanged)
  - cert-manager
  - cert-manager-config
  - metallb
  - metallb-config
  # ... rest of your enabled apps
```

**Commit the changes:**
1. Scroll to the bottom of the edit page
2. Add commit message: `feat: migrate cluster-forge to v2.2.0`
3. Click **"Commit Changes"**

> **  Important:** After committing, the cluster-forge ArgoCD application will show as "OutOfSync" or "Degraded". This is expected and will be synced after a while as long as autosync is active. Otherwise you can click "Sync" on the application page.

> **  Important:** The new ArgoCD application seaweedfs-config will continue showing "OutOfSync" even after it reaches a healthy state. This is due to an unused component called seaweed-ingress being in a persistent "Progressing" state. The ingress can not be disabled in our current version of SeaweedFS-operator, but it will be disabled in an upcoming release of cluster-forge

#### Verifying that seaweed is running
Before continuing, make sure all seaweedfs pods are running. The amount of pods might differ with your cluster size setting. 

```bash
kubectl -n seaweedfs-instance get pods

NAME                              READY   STATUS    RESTARTS
seaweed-filer-0                   1/1     Running   xxx
seaweed-master-0                  1/1     Running   xxx
seaweed-master-1                  1/1     Running   xxx   
seaweed-master-2                  1/1     Running   xxx
seaweed-volume-0                  1/1     Running   xxx
seaweed-volume-1                  1/1     Running   xxx
seaweed-volume-2                  1/1     Running   xxx
seaweedfs-admin-9b64677fd-j6b5h   1/1     Running   xxx
```


```bash
kubectl -n seaweedfs-operator get pods

NAME                                  READY   STATUS    RESTARTS   AGE
seaweedfs-operator-*****              1/1     Running   xxx        xxx
```

Once the pods are running, you can open the seaweed admin interface to see the contents of the buckets (initially empty).

**Navigate to Seaweed-Admin:**
1. Open your browser and go to `https://seaweed-admin.<your-domain>`
2. Find the value of the password called `admin-password` in the secret called `seaweedfs-admin-secret` in the namespace `seaweedfs-instance` 
3. Login with the credentials username: `admin`, password: `<the above secret>`
4. Navigate to Buckets and confirm that the `default-bucket` bucket exists

***Verify that AIWB API is using seaweed s3*** 
1. Using kubectl or k9s, inspect the pod `aiwb-api-****`, in the namespace `aiwb`.
2. Check that the environment variable `MINIO_URL` has the value `http://filer-s3.seaweedfs-instance.svc.cluster.local:80`

### Step 2: Run the Minio->Seaweed migration Job (5-10 minutes)

Download the latest version of cluster-forge (unless you already have it).
```bash
git clone https://github.com/silogen/cluster-forge.git
cd cd cluster-forge/scripts/utils
kubectl apply -f mirror-minio-to-seaweedfs-job.yaml
```

**Expected Output:**
```
🔧 MinIO to SeaweedFS S3 Mirror Job
================================================
...
"Waiting for SeaweedFS S3 service to be ready..."
...
"Starting mirror operation..."
...
✓ Mirror operation completed successfully!
...
Cleanup complete.
```
**Navigate to Seaweed-Admin:**
1. Go back to Seaweed-Admin as described above
2. Open Buckets and choose "default-bucket"
3. Verify that all the data has been mirrored 

### Step 3: Add seaweedfs storage to AIRM (optional)
***Navigate to AIRM UI***
1. Open your browser and go to `https://airmui.<your-domain>`
2. Find the value of the password called `USER_PASSWORD` in the secret called `airm-user-credentials` in the namespace `airm` 
3. Login with the credentials username: `devuser@<your-domain>`, password: `<the above secret>`
4. Navigate to Storage and click Add storage -> S3 Bucket
   Use the following config:
   - `Bucket URL`: `http://filer-s3.seaweedfs-instance.svc.cluster.local:80`
   - `Storage secret` Your existing secret with the same minio credentials (or a new one)
   - `Access Key Name`: `minio-access-key`
   - `Secret Key Name`: `minio-secret-key`

### Step 4: Test uploading/downloading datasets from AIWB (optional)
Make sure you can download your datasets from AIWB and that you can upload new datasets. 

### Step 5: Clean Up Old Minio Resources (3-5 minutes) (optional)
Once you have verified that all the data is mirrored to Seaweed, you can safely remove the minio applications.

*** Important: Make sure you removed the minio ArgoCD applications in Step 1. If you didn't, just go and remove the minio applications in your values.yaml file. The argocd application needs to be removed to allow deleting the resources. *** 

#### Remove the old minio Tenant and PVC (deleting the data)

```bash
kubectl -n minio-tenant-default delete tenant default-minio-tenant
> tenant.minio.min.io "default-minio-tenant" deleted from minio-tenant-default namespace
kubectl -n minio-tenant-default delete pvc -l v1.min.io/tenant=default-minio-tenant
> persistentvolumeclaim "data0-default-minio-tenant-pool-0-0" deleted from minio-tenant-default namespace
```
#### Remove the minio operator, the CRDs, and the minio namespaces

```
kubectl -n minio-operator delete deployment/minio-operator
> deployment.apps "minio-operator" deleted from minio-operator namespace
kubectl delete namespace minio-tenant-default
> namespace "minio-tenant-default" deleted
kubectl delete namespace minio-operator
> namespace "minio-operator" deleted

kubectl delete crds tenants.minio.min.io
> customresourcedefinition.apiextensions.k8s.io "tenants.minio.min.io" deleted
```

