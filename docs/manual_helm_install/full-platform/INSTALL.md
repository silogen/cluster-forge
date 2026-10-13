# Install AMD Enterprise AI with Helm

This document installs AMD Enterprise AI on a Kubernetes cluster. It is written
for an engineer who knows Kubernetes and Helm, and who has not seen this product
before. It explains each component before it installs it.

Read `UNINSTALL.md` to remove the installation.

## What you install

AMD Enterprise AI is two applications and a set of services that they need.

```
┌──────────┬──────────────────────────────────────────────────────────────┐
│ AIRM     │ AI Resource Manager. It owns the cluster: the projects, the  │
│          │ users, the GPU quota and the workloads. It is the control    │
│          │ plane of the product.                                        │
│ AIWB     │ AI Workbench. The web interface a data scientist uses. It    │
│          │ lists the models and it starts them.                         │
│ AIM      │ AMD Inference Microservice. One container image that holds   │
│          │ one model and the engine that serves it. An AIM exposes an   │
│          │ OpenAI-compatible API.                                       │
└──────────┴──────────────────────────────────────────────────────────────┘
```

You create an `AIMService` object to serve a model. The AIM engine then starts
the model on the GPUs and gives it an HTTP endpoint.

### Words this document uses

```
┌──────────────────┬──────────────────────────────────────────────────────┐
│ AIMClusterModel  │ One model that the cluster can serve. You do not     │
│                  │ write it. The AIM engine creates it when it reads a  │
│                  │ model image.                                         │
│ AIMClusterModel  │ A list of model images. You write this one. The AIM  │
│ Source           │ engine reads each image and creates the models.      │
│ AIMClusterProfile│ One way to run one model: the GPU count, the number  │
│                  │ format and the engine settings. The AIM engine       │
│                  │ creates it. You choose one when you serve a model.   │
│ AIMService       │ A running model. You write this one.                 │
│ Kueue            │ The job queue. It holds a workload until the GPUs it │
│                  │ asks for are free.                                   │
│ Kaiwo            │ The AMD scheduler layer above Kueue.                 │
│ KServe           │ The serving framework. The AIM engine creates a      │
│                  │ KServe InferenceService for each model you run.      │
│ cluster-forge    │ The AMD deployment system that installs this product │
│                  │ with ArgoCD. This document does NOT use it. It       │
│                  │ installs the same components with Helm.              │
│ cluster-bloom    │ The AMD installer that prepares a bare machine: the  │
│                  │ operating system, the GPU driver and Kubernetes. It  │
│                  │ is out of scope here. This document starts from a    │
│                  │ cluster that already runs.                           │
└──────────────────┴──────────────────────────────────────────────────────┘
```

## Before you start

### The cluster

```
┌──────────────────┬──────────────────────────────────────────────────────┐
│ Kubernetes       │ 1.28 or newer. The test used k3s 1.32.               │
│ Storage class    │ One default storage class that provisions a volume.  │
│ GPUs             │ Optional. AMD Instinct, with the host driver already │
│                  │ installed. Without GPUs the platform installs and    │
│                  │ runs, and it serves no model.                        │
│ Ingress          │ The scripts install Envoy Gateway. The cluster needs │
│                  │ a LoadBalancer address for it.                       │
│ Network          │ The cluster pulls from docker.io, ghcr.io, quay.io,  │
│                  │ registry.k8s.io and github.com.                      │
└──────────────────┴──────────────────────────────────────────────────────┘
```

Do not install an ingress controller of your own. The scripts install Envoy
Gateway, and two ingress controllers on one cluster conflict. On k3s, disable
Traefik with `--disable traefik`.

### Your workstation

```
┌──────────┬──────────────────────────────────────────────────────────────┐
│ helm     │ 3 or 4. Both work.                                           │
│ kubectl  │ Configured for the cluster, with cluster-admin rights.       │
│ bash     │ Version 4 or newer.                                          │
│ openssl  │ The scripts generate the passwords with it.                  │
│ git      │ Three scripts clone a repository. See "Limits" below.        │
│ curl     │ For the verification step.                                   │
└──────────┴──────────────────────────────────────────────────────────────┘
```

### A domain name

The product serves five host names under one domain. Choose the domain before
you start, because the installation writes it into Keycloak and you cannot
change it afterwards without a reinstall.

```
aiwbui.<domain>    the AI Workbench interface
airmui.<domain>    the AI Resource Manager interface
kc.<domain>        Keycloak, which signs users in
aiwbapi.<domain>   the AI Workbench API
airmapi.<domain>   the AI Resource Manager API
```

Point all five names at the Envoy Gateway address. For a test you can skip DNS
and use `curl --resolve`, which the verification step shows.

### A TLS certificate

The scripts create a self-signed certificate when you give none. A browser then
reports a warning. For a real installation, give your own certificate with
`TLS_CERT` and `TLS_KEY`.

## Install

### Step 1 — Set the variables

```bash
export DOMAIN=example.com
export STORAGE_CLASS=default
```

`STORAGE_CLASS` is the name of a storage class that `kubectl get storageclass`
reports.

On a cluster with one node, add this. The database chart asks for three replicas
by default, and three do not fit on one node:

```bash
export AIWB_CNPG_INSTANCES=1
```

To use your own certificate:

```bash
export TLS_CERT=/path/to/fullchain.pem
export TLS_KEY=/path/to/privkey.pem
```

Three scripts install a chart that is in this repository and in no registry.
Point them at your checkout, and they clone nothing:

```bash
export CLUSTER_FORGE_DIR=$(git rev-parse --show-toplevel)
```

Without this variable the scripts clone the repository into a temporary
directory. Set it, because a clone takes the `main` branch, and two installs on
two days then differ.

### Step 2 — Understand the passwords

The first script generates every password and writes them to `scripts/.secrets.env`.
The later scripts read that file.

**Keep this file.** It holds the Keycloak administrator password and every
database password. Without it you cannot sign in to a new Keycloak session, and
you cannot repeat the install against the same databases.

**Do not delete it between the scripts.** A script that finds no file generates
new passwords, and the services that already hold the old ones then fail.

### Step 3 — Run the dependency scripts

Run them in this order. Each one must report `rc=0` before you run the next.

```bash
cd scripts
for s in operators kyverno gateway openbao external-secrets keycloak postgres \
         rabbitmq object-storage cluster-auth observability compute aim-catalog; do
  echo "=== $s ==="
  bash "$s.sh" || { echo "FAILED at $s"; break; }
done
```

What each script installs, and why it is there:

```
┌──────────────────────┬──────────────────────────────────────────────────┐
│ operators.sh         │ cert-manager, External Secrets, OpenTelemetry    │
│                      │ and Envoy Gateway. The CRDs that everything else │
│                      │ needs.                                           │
│ kyverno.sh           │ Kyverno, and one policy. Read "The storage       │
│                      │ policy" below. Do not skip this script.          │
│ gateway.sh           │ The Gateway object that serves the five host     │
│                      │ names, and its TLS certificate.                  │
│ openbao.sh           │ OpenBao, the secret store. It holds the          │
│                      │ passwords of step 2. REQUIRED. Read "The secret  │
│                      │ store" below.                                    │
│ external-secrets.sh  │ The ExternalSecret objects that copy a secret    │
│                      │ from OpenBao into a namespace.                   │
│ keycloak.sh          │ Keycloak and its database. It signs users in.    │
│ postgres.sh          │ The PostgreSQL databases of AIRM and AIWB.       │
│ rabbitmq.sh          │ The message broker that AIRM uses.               │
│ object-storage.sh    │ SeaweedFS, which stores the models and the files │
│                      │ of a project.                                    │
│ cluster-auth.sh      │ The service that gives a user a kubeconfig.      │
│ observability.sh     │ Prometheus, Grafana, Loki and Tempo. AIRM reads  │
│                      │ the GPU metrics from Prometheus.                 │
│ compute.sh           │ The GPU stack: the AMD GPU operator, Kueue,      │
│                      │ Kaiwo, KServe, KEDA, KubeRay and the AIM engine. │
│ aim-catalog.sh       │ The model catalog. Read "The model catalog".     │
└──────────────────────┴──────────────────────────────────────────────────┘
```

This takes about 15 minutes. `compute.sh` is the longest, because it pulls large
images.

#### The secret store

`openbao.sh` is required. The README of an older version calls it optional and
offers `secrets.sh` instead. That is wrong.

`secrets.sh` creates the Kubernetes Secrets, and it does NOT create the
`ClusterSecretStore`. Four ExternalSecrets need that store, in three namespaces.
Without it every script reports success, the install finishes, and the
`airm-configure` job never completes. Nothing serves.

#### The storage policy

The AIM engine creates the model cache volume with the `ReadWriteMany` access
mode. Many storage classes support `ReadWriteOnce` only, and the local-path
provisioner of k3s is one of them. The volume then stays `Pending` for ever and
no model starts.

`kyverno.sh` installs a Kyverno policy that rewrites `ReadWriteMany` to
`ReadWriteOnce` when it detects such a storage class. It applies the policy only
when it is needed. A cluster with a storage class that supports `ReadWriteMany`,
such as Longhorn or NFS, gets no policy.

The policy changes a volume when it is created. Run `kyverno.sh` in the position
shown above, before any other script creates a volume.

#### The model catalog

The AIM engine does not know any model until you tell it where to look.
`aim-catalog.sh` creates an `AIMClusterModelSource`, which lists the model
images. The engine then runs one job for each image, reads the model metadata,
and creates an `AIMClusterModel` and its profiles.

The default list holds one model, `openai/gpt-oss-20b`. Change it with:

```bash
export AIM_MODEL_IMAGES="amdenterpriseai/aim-openai-gpt-oss-20b:0.11.1 amdenterpriseai/aim-qwen-qwen3-32b:0.11.1"
```

Each image starts a job that pulls several gigabytes. Keep the list short.

**Choose a model with no gated source repository.** The `meta-llama` and the
`google/gemma` models need an approved HuggingFace account and an access token.
The download fails with `Access denied. This repository requires approval.` The
`openai/gpt-oss` and the Qwen models need no token.

### Step 4 — Install the two charts

```bash
helm upgrade --install airm \
  oci://registry-1.docker.io/amdenterpriseai/airm-chart \
  --version 2.0.3 --namespace airm --create-namespace \
  --set airm-api.airm.appDomain="${DOMAIN}" \
  --wait --timeout 15m

helm upgrade --install aiwb \
  oci://registry-1.docker.io/amdenterpriseai/aiwb-chart \
  --version 2.0.3 --namespace aiwb --create-namespace \
  --set appDomain="${DOMAIN}" \
  --wait --timeout 15m
```

Install AIRM first. AIWB reads the configuration that AIRM writes.

Each chart takes about one minute.

## Verify

### The sign-in pages answer

```bash
IP=$(kubectl get svc -n envoy-gateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')

for h in aiwbui airmui kc aiwbapi airmapi; do
  printf '%s ' "$h"
  curl -sk -o /dev/null -w '%{http_code}\n' \
    --resolve "$h.${DOMAIN}:443:${IP}" "https://$h.${DOMAIN}/"
done
```

A correct install gives these codes:

```
┌──────────────────┬──────┬────────────────────────────────────┐
│ aiwbui           │ 307  │ it redirects to the sign-in page   │
│ airmui           │ 307  │ it redirects to the sign-in page   │
│ kc               │ 302  │ Keycloak answers                   │
│ aiwbapi          │ 404  │ correct: the API serves no path /  │
│ airmapi          │ 404  │ correct: the API serves no path /  │
└──────────────────┴──────┴────────────────────────────────────┘
```

A `404` from the two API names is a PASS. The API has no page at the root.

### The registration job completed

```bash
kubectl get job -n airm airm-configure
```

It must report `Complete`. This job registers the cluster with AIRM. When it
restarts in a loop, read "The install finishes and nothing serves" below.

### The GPUs are available

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.amd\.com/gpu}{"\n"}{end}'
```

Each GPU node must report its GPU count. An empty value means the node offers no
GPU to the scheduler, and no model can run. Read "A node reports no GPU" below.

### The catalog holds a model

```bash
kubectl get aimclustermodels
```

## Serve a model

### 1. Choose a profile

A profile is one way to run one model. Each model has several: a different GPU
count, a different number format.

```bash
kubectl get aimclusterprofiles \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.aimId}{"  gpus="}{.spec.acceleratorCount}{"  "}{.spec.acceleratorModel}{"\n"}{end}'
```

Choose one that fits the GPUs you have. The profile name is long and it holds a
hash, so copy it exactly.

### 2. Create the service

AIRM creates a project namespace called `demo`. Use it, or use your own project
namespace.

```yaml
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: my-model
  namespace: demo
spec:
  replicas: 1
  profile:
    name: <the profile name from step 1>
  caching:
    mode: Dedicated
```

```bash
kubectl apply -f my-model.yaml
```

Use `caching.mode: Dedicated` on a storage class that supports `ReadWriteOnce`
only. `Shared`, the default, asks for `ReadWriteMany`.

### 3. Wait

```bash
kubectl get aimservice -n demo -w
```

The service moves from `Starting` to `Running`. Two jobs run first: one measures
the model, and one downloads the weights. The engine then starts the server.
A 20-billion-parameter model takes about 4 minutes on a fast connection.

Read the conditions when it stops in `Starting`:

```bash
kubectl get aimservice my-model -n demo \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

### 4. Call it

```bash
POD=$(kubectl get pods -n demo --no-headers | grep predictor | awk '{print $1}')

kubectl exec -n demo "$POD" -- curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-oss-20b","messages":[{"role":"user","content":"Hello"}],"max_tokens":40}'
```

The model also answers through the gateway, on the host name that the
`HTTPRoute` of the service gives.

## When something fails

### A script stops

Read the message of the LAST script that ran. A failure early in the order
causes a message later that names a different component. A missing CRD usually
means that `operators.sh` did not complete.

Each script is safe to run again. Every step uses `helm upgrade --install`.

### The install finishes and nothing serves

Look at the `airm-configure` job. When it restarts in a loop and its log reports
`Secret status: SyncedError`, an ExternalSecret cannot read the secret store:

```bash
kubectl get clustersecretstore
kubectl get externalsecrets -A
```

No `ClusterSecretStore` means that `openbao.sh` did not run. Run it, then
`external-secrets.sh`.

### A node reports no GPU

```bash
kubectl get deviceconfig -n kube-amd-gpu
kubectl get pods -n kube-amd-gpu
```

A `DeviceConfig` object starts the device plugin, and the device plugin offers
the GPUs to Kubernetes. `compute.sh` creates it. Without the object the node
detects every GPU and advertises none.

Check that the host driver works, with `amd-smi list` on the node. The
`DeviceConfig` sets `driver.enable: false`, because it expects the driver on the
host already.

### A model stays Pending

```bash
kubectl get pvc -n demo
kubectl describe pvc -n demo | grep -A3 ProvisioningFailed
```

`NodePath only supports ReadWriteOnce` means the storage policy is absent. Run
`kyverno.sh`, delete the `AIMService` and the `AIMArtifact`, and create the
service again. A volume keeps the access mode it was created with.

### A model download fails

`Access denied. This repository requires approval.` means the model source
repository is gated. Use a model with no gate, or give the engine a HuggingFace
token.

## Limits

Read these before you give this document to a customer.

**It is not helm-only yet.** Three dependency scripts clone the cluster-forge
repository and install a chart from a path in it, because those charts are in no
registry. Two more steps, the storage policy and the model catalog, write
Kubernetes objects with `kubectl` for the same reason. A registry must hold
these charts before this is a Helm-only procedure.

**The clone takes an unpinned branch.** The three scripts clone the `main`
branch. Two installs on two days can therefore differ. Set `CLUSTER_FORGE_REF`
to pin a tag.

**One domain, one install.** The domain goes into the Keycloak realm. To change
it, uninstall and install again.

**The model catalog is a copy.** `aim-catalog.sh` holds a list of image names
that AMD publishes elsewhere. The list goes out of date. Check for a newer tag
before you install.
