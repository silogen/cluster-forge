# Namespaces left to delete

Running list of namespaces emptied by the uninstall walk, kept for a single final
sweep rather than deleting them step by step.

The dedicated script is `uninstall-leftovers.sh`. After `uninstall-all.sh` (or the
OpenShift operator uninstall that mirrors it) has walked every step, run:

```bash
KUBECONFIG=docs/openshift/kube.yaml ./docs/openshift/uninstall/uninstall-leftovers.sh          # dry run
KUBECONFIG=docs/openshift/kube.yaml ./docs/openshift/uninstall/uninstall-leftovers.sh --delete  # for real
```

It does two phases, in this order:

1. **Unclaimed objects** — Kyverno webhooks; the whole OpenBao agent injector (webhook,
   RBAC, and `deploy`/`svc`/`sa` in `cf-openbao`), which today's chart no longer emits.
2. **Namespace sweep** — the list below, cascading everything still inside (workbench
   runtime, TLS secrets, PVCs, …).

`uninstall-all.sh` never deletes a namespace unless `--namespaces` is passed,
because a namespace is not one step's to delete: several steps share one, and the
first of them to run would take the others with it. So they accumulate here as the
walk goes on, and go at the end via `uninstall-leftovers.sh` (or one pass with
`--namespaces` on the walk, which does not cover the cluster-scoped half).


A namespace is listed once the walk has removed everything its steps declared and
the only namespaced objects left are the ones OpenShift creates with any namespace:
the `builder` / `default` / `deployer` ServiceAccounts and their `*-dockercfg-*`
secrets. Check with a namespaced-only query, not `kubectl get all`, which also lists
cluster-scoped custom resources (the AIM ones, for instance) and makes an empty
namespace look busy:

```bash
kubectl get pod,deploy,rs,svc,sa,cm,secret,pvc,job,externalsecret -n <ns> --no-headers \
  | grep -v -e kube-root-ca -e openshift-service-ca
```

Anything still in a namespace at sweep time that no chart declares -- served models,
workspaces, operator-generated secrets, volumes claimed at runtime -- is deleted with
it. That is the point of the sweep, and the reason to look before running it.

Two kinds of namespace turn up here, and the difference decides how each one goes.

A step's `namespace:` field is not in any render -- the install creates it with `kubectl
create namespace` -- so nothing declares it and `--namespaces` is the only thing that
takes it. But a namespace written into a step's `extraObjects` *is* declared, and the walk
deletes it like any other object once `--namespaces` is on. `aiwb-infra` (UNDO 21) declares
eleven of them, which is why that step reports eleven kept.

| Namespace | Emptied by | Declared by | Verified |
|---|---|---|---|
| `kaiwo-system` | `kaiwo-config`, `kaiwo`, `kaiwo-crds` (UNDO 2-4) | `aiwb-infra` (21) | 2026-08-18 |
| `kueue-system` | `kueue-config`, `kueue` (UNDO 5-6) | nothing | 2026-08-18 |
| `rabbitmq-system` | `rabbitmq` (UNDO 7) | `rabbitmq` (7) | 2026-08-18 |
| `seaweedfs-operator` | `seaweedfs-operator` (UNDO 13) | nothing | 2026-08-18 |
| `cluster-auth` | `cluster-auth-shim` (UNDO 18) | `aiwb-infra` (21), `ai-gateway-base` (39) | 2026-08-18 |
| `keycloak` | `keycloak` (16), `aiwb-infra-cnpg-secrets` (20), `aiwb-infra` (21) | `aiwb-infra` (21) | 2026-08-18 |
| `aiwb` | `aiwb-infra` (UNDO 21) | `aiwb-infra` (21) | 2026-08-18 |
| `airm` | `aiwb-infra` (UNDO 21) | `aiwb-infra` (21) | 2026-08-18 |
| `demo` | `aiwb-infra` (UNDO 21) | `aiwb-infra` (21) | 2026-08-18 |
| `metallb-system` | `aiwb-infra` (UNDO 21) | `aiwb-infra` (21) | 2026-08-18 |
| `minio-tenant-default` | `aiwb-infra` (UNDO 21) | `aiwb-infra` (21) | 2026-08-18 |
| `aim-system` | `aim-engine` (22), `aim-engine-crds` (23) | `aiwb-infra` (21) | 2026-08-18 |
| `kserve-system` | `kserve` (29), `kserve-crds` (30) | nothing | 2026-08-18 |
| `envoy-ai-gateway-system` | `envoy-ai-gateway` (33) | `aiwb-infra` (21) | 2026-08-18 |
| `envoy-gateway-system` | `envoy-gateway` (34) | `aiwb-infra` (21) | 2026-08-18 |
| `keda` | `kedify-otel` (40), `keda` (41) | nothing | 2026-08-18 |
| `otel-lgtm-stack` | `otel-lgtm-stack` (42) | nothing | 2026-08-18 |
| `cf-openbao` | `openbao-init-job`–`openbao` (44–47) | nothing | 2026-08-18 |
| `external-secrets` | `external-secrets` (49) | nothing | 2026-08-18 |
| `opentelemetry-system` | `opentelemetry-operator` (50) | nothing | 2026-08-18 |
| `cert-manager` | `cert-manager` (51) | nothing | 2026-08-18 |
| `kyverno` | `kyverno` (57) | nothing | 2026-08-18 |
| `appwrapper-system` | `appwrapper` (58) | nothing | 2026-08-18 |
| `cnpg-system` | `cnpg-operator` (59) | nothing | 2026-08-18 |

Of the three `aiwb-infra` declares that were not empty at UNDO 21, `aim-system` emptied at
23, `envoy-ai-gateway-system` at 33, and `envoy-gateway-system` at 34 (`workbench` is still
to go). That is the cascade the script exists to prevent: a single
`--delete --namespaces aiwb-infra` would take AIM, the Envoy gateway and every served
model with it, twelve steps before their turn.

`envoy-gateway-system` still holds operator-generated TLS/HMAC secrets (`envoy`,
`envoy-gateway`, `envoy-rate-limit`, `cluster-tls`, `envoy-oidc-hmac`,
`ai-gateway-envoy-gateway-system`) that no chart declares; the namespace sweep takes them.

`cf-openbao` after UNDO 44–47 still holds the agent injector (`deploy/openbao-agent-injector`,
its Service, SA and `MutatingWebhookConfiguration/openbao-agent-injector-cfg`), the PVC
`data-openbao-0` (StatefulSet volumeClaimTemplates are not deleted with the STS), the
init secrets `openbao-keys` / `openbao-user`, and a leftover `pod/openbao-server-test`
(Helm test hook, never in the uninstall inventory). The current chart render does not
emit the injector for this install shape, so the step cannot claim it. The namespace sweep
takes all of that **except** the cluster-scoped webhook/RBAC of the injector.

### Kyverno webhooks after UNDO 57

The chart inventory deleted cleanly (65 objects). Ten webhook configurations remain,
created at runtime by the controllers themselves (`managedFields.manager`: `kyverno` or
`cleanup-controller`), so no step declares them and deleting the `kyverno` namespace does
not take them either. Clear before or after the sweep:

```bash
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l webhook.kyverno.io/managed-by=kyverno 2>/dev/null
# or by name:
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name \
  | grep kyverno | xargs -r kubectl delete
```

Also left in the namespace (sweep takes them): Helm test pods, TLS secrets the controllers
wrote, and the stuck post-upgrade `job/kyverno-migrate-resources` (hooks are not in the
uninstall inventory).

## Not empty, and what the sweep will take with them

These have had their steps' objects removed but still hold runtime state. Some of it
still has an owner further down the order and will cascade on its own; the rest has
nothing left to collect it and only goes with the namespace.

### `workbench` (`aiwb`, UNDO 9)

Orphans, in the strict sense: written by the ai-gateway-discovery controller, which
UNDO 8 removed, with no ownerReferences and declared by no chart. Nothing will collect
them, and the deployments keep running until the sweep.

    deploy/workbench-wb-aim-2c5c72f3-200f19db   svc/…:9002   inferencepool/…
    deploy/workbench-wb-aim-70fee534-fd0d8695   svc/…:9002   inferencepool/…

The controller creates four objects per served model and sets an ownerReference on only
one of them. The AIGatewayRoute points at its `InferenceService/wb-aim-*`; the endpoint
picker Deployment, its Service and the InferencePool -- same name, same lifecycle, same
namespace as that InferenceService -- carry none, so only the route is garbage-collected.
Worth reporting upstream: the owner should be the InferenceService the route already
uses, not the controller's own Deployment, or every upgrade of the controller would
delete the endpoint pickers of every served model.

Still owned, so these cascade when their owners go and need nothing here: the
`wb-aim-*-predictor` deployments and the `aigatewayroute`s hang off
`InferenceService/wb-aim-*` (KServe, UNDO 28-30), and the AIM models, services and
profile caches go with the AIM steps.

446Gi across 8 PVCs, which the sweep deletes: three `hf---*` model caches (117Gi,
37Gi, 33Gi), three `s3---*` caches (33Gi each), `pvc-mlflow-workbench` (60Gi) and
`pvc-devuser-apps-smc-4124-jd-amd-com` (100Gi).

### `seaweedfs-instance` (`seaweedfs-config`, UNDO 11)

    pvc/mount0-seaweed-volume-0   25Gi

The volume server's StatefulSet was created by the operator from the `seaweed` CR, and
its PVC came from a volumeClaimTemplate. Kubernetes leaves those behind on purpose when
a StatefulSet goes, so no chart declares it and nothing deletes it before the sweep. Its
PV is `reclaimPolicy: Delete`, so the disk goes when the PVC does.

Not a namespace, but on the same "later" list: `kube-system` keeps whatever a step put
in it (the Kaiwo GPU-aware scheduler was one) and is never deleted. Those objects are
declared by their step and go with it, so nothing is pending there.

## What the sweep does not solve: finalizers outliving their controller

Deleting a namespace deletes every namespaced object in it, so all of the above goes.
What it does not do is bypass a finalizer. A namespace stays in `Terminating` until the
objects inside finish deleting, and an object whose finalizer nobody will remove never
finishes. So a sweep is not a way out of the problem below -- it inherits it.

This matters twice over, because a namespace sweep is not always available: the namespace
may be shared, owned by another team, or required to outlive the application.

The uninstall walk removes each controller before the runtime objects its finalizers
guard. It cannot do otherwise: those objects are not declared by any chart, so they have
no position in the order, and the only steps that take them are the CRD steps, which
reverse order puts *after* the controller. Every operator that finalizes its own CRs hits
this:

| CR (in `workbench`) | Finalizer | Controller removed at | CRs removed at |
|---|---|---|---|
| `inferenceservice/wb-aim-*` | `inferenceservice.finalizers` | `kserve` (29) | `kserve-crds` (30) |
| `inferenceservice/wb-aim-*` | `aigateway.silogen.ai/finalizer` | `ai-gateway-discovery` (8) | `kserve-crds` (30) |
| `aimservice/*` | `aim.eai.amd.com/cache-cleanup` | `aim-engine` (22) | `aim-engine-crds` (23) |
| `aimmodel/*` | `aim.eai.amd.com/model-profiles-cleanup` | `aim-engine` (22) | `aim-engine-crds` (23) |
| `aimprofilecache/*` | `aim.eai.amd.com/profile-cache-artifact-cleanup` | `aim-engine` (22) | `aim-engine-crds` (23) |
| `aigatewayroute/*` | `aigateway.envoyproxy.io/finalizer` | `envoy-ai-gateway` (33) | cascades at 30, controller still up |

Only the last one is safe, and only by luck of the order.

### Fixes, roughly in order of how well they hold

**Delete the runtime content first, while every controller is still up.** Done: the
`[DRAIN]` phase in `uninstall-all.sh` runs before the walk, deletes every custom
resource an operator created, and waits for the finalizers to run. On by default for a
whole-order run, `--drain` on a partial one, `--keep-runtime` off. Two filters decide what
it touches, and the second one is the reason it is safe to run at all:

- the CRD has to be one this install applied. The values file declares
  `monitoring.coreos.com` and `kmm.sigs.x-k8s.io` CRDs, but on OpenShift those were
  installed by `cluster-version-operator` and OLM, and their custom resources are the
  platform's own monitoring stack and GPU modules. Without this filter the drain proposed
  deleting 39 of them, including `prometheus/k8s` and `alertmanager/main`.
- the resource must *not* have been applied by this install, or it belongs to a step and
  is left to it. Judged on the creating field managers only (`cluster-forge/*`, `kubectl`,
  `kubectl-client-side-apply`, `kubectl-create`, `helm`); `kubectl-edit` and
  `kubectl-annotate` do not count, or an AIMService the AIWB backend created and someone
  later annotated would read as declared and be left stranded.

Two holes found while running it, both worth fixing in the script:

- **An object with an ownerReference should not be drained.** The drain deleted the five
  `AIMClusterModel`s and their 30 profiles and templates, and the AIM controller recreated
  all 35 within seconds, because they descend from `aimclustermodelsource/amd-aim-radeon-
  0.12.0`, which the drain correctly left alone. Deleting an owned object while its owner
  and controller are both up is futile, and the wait loop never converges. Owned objects
  cascade when the owner goes; only the ownerless ones need this.
- **Applied by hand is not the same as declared by a step.** That model source was applied
  with `kubectl`, so the drain read it as a step's object, but no step owns it:
  `install-old.sh` only renders it to `aim-cluster-model-source-deploy-manually.yaml` and
  prints a warning to apply it manually. Nothing in the walk will ever delete it, and while
  the AIM controller lives it keeps regenerating the 35. Deleted by hand here; a manual
  install step needs a manual uninstall step, or the install should apply it.

Also: the wait loop's timeout counts its own `sleep`s, not the 75 existence checks each
round costs, so "300s" is many minutes against a cluster this far away.

What the drain does not cover: types whose CRD the platform owns, `HTTPRoute` being the
one that matters here (`gateway.networking.k8s.io` belongs to OpenShift's
`ingress-operator`). The AI gateway's generated HTTPRoutes are owned by the AIGatewayRoutes
the drain does delete, so they cascade -- but a runtime resource of a platform-owned type
with no owner would survive, and only the namespace would take it.

**ownerReferences on everything a controller creates.** Garbage collection then handles
the children of a deleted object without a finalizer and without the controller being
alive. For ai-gateway-discovery the owner should be the `InferenceService` the
AIGatewayRoute already points at -- not the controller's own Deployment, which would make
every controller upgrade delete the endpoint pickers of every served model.

**A pre-delete hook, or a controller that drops its finalizers on shutdown.** Either lets
a chart uninstall leave nothing that depends on it. This is what would have saved the two
InferenceServices here.

**StatefulSet PVC retention.** For the seaweed volume PVC, `persistentVolumeClaimRetention
Policy: {whenDeleted: Delete}` on the StatefulSet the operator generates (GA, and this
cluster is v1.35.5), or ownerReferences from the `seaweed` CR onto the PVCs. Failing that,
the PVC is at least labelled (`app.kubernetes.io/managed-by=seaweedfs-operator`,
`app.kubernetes.io/instance=seaweed`), so a label sweep can find it -- unlike the
discovery orphans, where the Service and InferencePool carry no labels at all and the
Deployment only an opaque `airm.silogen.ai/workload-id`.

### Escape hatch for the ones already stranded

The two InferenceServices in `workbench` already hold `aigateway.silogen.ai/finalizer`
from a controller that is gone. Drop it before the walk reaches `kserve-crds` (UNDO 30),
or that step, and any later namespace sweep, hangs:

```bash
kubectl get inferenceservice -n workbench -o name | xargs -r -I{} \
  kubectl patch {} -n workbench --type=merge \
  -p '{"metadata":{"finalizers":["inferenceservice.finalizers"]}}'
```

The AIM objects are not stranded yet -- `aim-engine-controller-manager` is still up. They
will be the moment UNDO 22 runs, so delete them before it, not after.

## `skipInstallWhenExists`, read backwards

The install asks whether an object is already on the cluster and, if it is, leaves its own
copy uninstalled. Read backwards that is the wrong question: existence says nothing about
whose copy is here, and both wrong answers do damage -- deleting what the platform installed,
or skipping what this install did and leaving the step half up. Two things have to hold for
the guard's match to be the step's own, and neither is enough alone.

**The field managers have to say this install applied it.** Otherwise it is OLM's or the
`cluster-version-operator`'s. Note that this test cannot be replaced by "is it in the step's
render": `amd-gpu-operator-crds` and `prometheus-crds` both render the very CRD their guard
names, and both must keep their hands off it.

**The step's render has to name it.** Otherwise a `kubectl apply` by hand counts as the
installer's, because that is what it looks like -- `kubectl-client-side-apply` either way.

Against this cluster the two tests skip all seven guarded steps, each for its own reason:

| Step | Guard | Verdict |
|---|---|---|
| `prometheus-crds` (52) | `crd/alertmanagers.monitoring.coreos.com` | `cluster-version-operator` applied it |
| `gateway-api-crds` (48) | `crd/httproutes.gateway.networking.k8s.io` | `ingress-operator` applied it |
| `kserve-crds` (30) | `deployment/kserve-controller-manager` in `redhat-ods-applications` | absent, so the guard never matches and the step deletes normally |
| `amd-gpu-nodefeaturerule` (24) | a labelled node | `kubelet` and `machine-config-operator` own nodes |
| `amd-gpu-operator-config` (25) | a `deviceconfigs.amd.com` | applied with kubectl, but as `test-deviceconfig`, which the step does not declare |
| `amd-gpu-operator` (26) | `crd/deviceconfigs.amd.com` | `catalog` and `olm` applied it |
| `amd-gpu-operator-crds` (27) | `crd/deviceconfigs.amd.com` | `catalog` and `olm` applied it |

The GPU block comes apart along the line you would draw by hand, with nothing to declare:
the operator came from OperatorHub -- `subscription/amd-gpu-operator` against
`certified-operators`, CSV `amd-gpu-operator.v1.5.2`, alongside Kernel Module Management --
so its operator and CRDs are OLM's to remove, and the DeviceConfig on top of them was written
by hand.

### The DeviceConfig the guard matches is not the one the chart names

`amd-gpu-operator-config` renders `DeviceConfig/gpu-operator`. What is on the cluster is
`DeviceConfig/test-deviceconfig`, hand-edited and applied on 6 Aug, and there is no
`gpu-operator` at all -- so the step installed nothing here, and UNDO 25 leaves both it and
`configmap/gpu-config` alone. Which is what should happen: `test-deviceconfig` sets
`spec.metricsExporter.config.name: gpu-config`, so taking the ConfigMap while leaving the
DeviceConfig would point the exporter at nothing, and the guard would then match the surviving
DeviceConfig on the next install and skip putting the ConfigMap back.

This is the same shape as `aimclustermodelsource/amd-aim-radeon-0.12.0`: an object a step
sketches but a person applied under another name. There the object had to go and only a hand
could do it; here it stays. Either way no step can claim it, so no step touches it.

`configmap/gpu-config` was applied by hand the same morning, so the whole GPU block is
hand-built and none of it is this script's.

## `--skip`, for the steps a cluster had done to it by hand

Field managers cannot see everything: `kubectl-client-side-apply` is what a person and
`install.sh` both leave behind, and the render test above only catches the cases where the
hand chose a different name. So there is an explicit way to say it:

```bash
export CF_SKIP="amd-gpu-nodefeaturerule amd-gpu-operator-config amd-gpu-operator amd-gpu-operator-crds"
```

Read from the environment as well as from `--skip a,b`, because a teardown is a long series of
single-step runs and exporting it once covers all of them -- the run where a flag is forgotten
is the run that deletes the step. `--skip` also wins over an app named on the command line,
for the same reason. `--list` marks what it will leave, and every run prints the list before it
starts.

It is not a field in `values-openshift.yaml` on purpose. That file says what an install does on
every cluster; what was done to one cluster by hand belongs to the invocation, and committing
it would skip the step on clusters that never had it.

A skipped step also keeps its CRDs out of the drain. Draining is per CRD, so without that,
`--skip kaiwo-crds` on a whole-order run would still delete every KaiwoJob and KaiwoService on
the way past -- emptying the component the skip was asked for to keep.
