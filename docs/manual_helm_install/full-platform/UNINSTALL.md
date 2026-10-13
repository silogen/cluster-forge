# Remove AMD Enterprise AI

This document removes the installation that `INSTALL.md` makes. It returns the
cluster to the state it had before.

## Run the script

```bash
bash scripts/uninstall.sh
```

It takes about 5 minutes. It reports `rc=0`.

The script is safe to run again. Run it a second time when the first run reports
an error.

## Why a script, and not `helm uninstall`

`helm uninstall` for each release does NOT remove this product. Three things
stay behind, and each one stops the cluster from reaching a clean state.

### 1. AIRM puts a finalizer on every namespace

AIRM adds `airm.silogen.ai/namespace-finalizer` to **every** namespace of the
cluster. This includes `kube-system`, `kube-public`, `kube-node-lease` and
`default`, which have no relation to this product.

A finalizer blocks a delete until the controller that owns it removes it. When
you delete AIRM first, no controller is left to remove the finalizer.

**The effect: no namespace on the cluster can be deleted again, for ever.** This
includes the namespaces of your own applications. A restart of the control plane
does not release them. Only a manual patch of each namespace does.

The script removes the finalizer itself, before it deletes the namespaces. It
leaves a namespace unchanged when that namespace also holds a finalizer that
AIRM does not own.

### 2. A served model leaves three more finalizers

A model that ran leaves these:

```
┌──────────────────────────────────────────────┬──────────────────────────┐
│ aim.eai.amd.com/profile-cache-artifact-      │ AIMProfileCache          │
│ cleanup                                      │                          │
│ airm.silogen.ai/workloads-finalizer          │ InferenceService,        │
│                                              │ HTTPRoute, Service, Pod, │
│                                              │ ReplicaSet               │
│ inferenceservice.finalizers                  │ InferenceService (KServe)│
└──────────────────────────────────────────────┴──────────────────────────┘
```

Each one holds its namespace in `Terminating`. The script clears all three while
the controllers still run.

### 3. Helm keeps a CRD

Helm never deletes a CRD that a chart ships in its `crds/` directory. About 25
CRDs stay behind after the releases are gone, and the next install then inherits
them. The script deletes the CRD groups that the installation creates.

## Verify

```bash
echo "releases: $(helm list -A --no-headers | grep -c '[^[:space:]]')"
echo "CRDs:     $(kubectl get crd --no-headers | wc -l)"
echo "volumes:  $(kubectl get pv --no-headers | wc -l)"
echo "webhooks: $(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration --no-headers | wc -l)"
kubectl get namespace
```

A complete removal reports zero releases, zero volumes and zero webhooks. The
namespace list holds only the namespaces of the cluster itself.

On a k3s cluster the CRD count is not zero, because k3s owns the
`k3s.cattle.io`, `helm.cattle.io` and `traefik.io` groups. Ignore those.

## What it does not remove

```
┌──────────────────────┬──────────────────────────────────────────────────┐
│ scripts/.secrets.env    │ Your passwords. Delete the file yourself when you │
│                      │ do not install again.                            │
│ The GPU host driver  │ The installation never touched it.               │
│ Your storage class   │ The script deletes the volumes of the product,   │
│                      │ and not the class.                               │
│ Kubernetes itself    │ The cluster keeps running.                       │
└──────────────────────┴──────────────────────────────────────────────────┘
```

## When the script leaves something

### A namespace stays in Terminating

Find what holds it:

```bash
kubectl get namespace <name> -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}: {.message}{"\n"}{end}'
```

`NamespaceFinalizersRemaining` names the finalizer. `NamespaceContentRemaining`
names the object kind. Clear it:

```bash
kubectl patch <kind> <name> -n <namespace> --type=merge -p '{"metadata":{"finalizers":[]}}'
```

Run `scripts/uninstall.sh` again afterwards.

### A CRD stays

```bash
kubectl get crd | grep -E 'amd\.com|kaiwo|kserve|kueue|gateway|external-secrets|kyverno'
kubectl delete crd <name>
```

A CRD delete that does not return means an object of that kind still holds a
finalizer. Clear the object first.
