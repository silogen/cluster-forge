#!/usr/bin/env bash
# Removes the releases and namespaces created by the dependency scripts and the AIRM and AIWB charts.
#
# AIRM puts the finalizer airm.silogen.ai/namespace-finalizer on EVERY namespace,
# and airm.silogen.ai/kaiwoqueueconfig-finalizer on the KaiwoQueueConfig. The
# AIRM controller is the only thing that removes them. This script deletes AIRM,
# so it must remove those finalizers itself. If it does not, no namespace on the
# cluster can be deleted again, and the kaiwo CRD delete never returns.
set -euo pipefail

KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-180s}"

helm_uninstall() {
  helm uninstall "$1" --namespace "$2" --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" || true
}

kdelete() {
  kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" "$@" || true
}

namespace_finalizers() {
  kubectl get namespace "$1" \
    -o jsonpath='{range .metadata.finalizers[*]}{@}{"\n"}{end}' 2>/dev/null
}

# Removes the AIRM finalizer from every namespace that carries it. Keeps a
# namespace unchanged when it also carries a finalizer that AIRM does not own,
# because that finalizer belongs to a controller this script does not manage.
strip_airm_namespace_finalizers() {
  local ns all others
  for ns in $(kubectl get namespace \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    all="$(namespace_finalizers "${ns}")"
    printf '%s\n' "${all}" | grep -q 'airm\.silogen\.ai' || continue
    others="$(printf '%s\n' "${all}" | grep -v 'airm\.silogen\.ai' | grep -v '^$' || true)"
    if [[ -n "${others}" ]]; then
      echo "WARNING: namespace ${ns} also holds ${others}. Left unchanged." >&2
      continue
    fi
    if kubectl patch namespace "${ns}" --type=json \
        -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1; then
      echo "removed the AIRM finalizer from namespace ${ns}"
    fi
  done
}

# Clears the finalizers on every object of one kind, in every namespace. The
# controller that owns the finalizer is already gone at each call site, so no
# controller removes it and the delete of the object, its CRD or its namespace
# blocks. Accepts a cluster-scoped kind, which reports an empty namespace.
strip_resource_finalizers() {
  local kind="$1" ns name
  kubectl get "${kind}" --all-namespaces \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while IFS='|' read -r ns name; do
        [[ -z "${name}" ]] && continue
        if [[ -n "${ns}" ]]; then
          kubectl patch "${kind}" "${name}" --namespace "${ns}" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
            && echo "cleared the finalizers on ${kind} ${ns}/${name}"
        else
          kubectl patch "${kind}" "${name}" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
            && echo "cleared the finalizers on ${kind} ${name}"
        fi
      done || true
  # A kind whose CRD is already gone makes kubectl exit non-zero. With
  # `set -e` and `pipefail` that ends the script, so absorb it here.
  return 0
}

# AIRM owns airm.silogen.ai/secret-finalizer on the ExternalSecret and
# airm.silogen.ai/kaiwoqueueconfig-finalizer on the KaiwoQueueConfig. The
# ExternalSecret in the demo namespace stops that namespace from draining.
strip_airm_object_finalizers() {
  strip_resource_finalizers externalsecrets
  strip_resource_finalizers kaiwoqueueconfigs
  # The AIM engine puts aim.eai.amd.com/profile-cache-artifact-cleanup on the
  # AIMProfileCache. A served model leaves one, and it stops its namespace.
  strip_resource_finalizers aimprofilecaches
  # kserve owns inferenceservice.finalizers on the InferenceService that the AIM
  # engine creates for a served model. This script deletes kserve first, so no
  # controller removes that finalizer and the namespace stays in Terminating.
  strip_resource_finalizers inferenceservices
  strip_airm_core_finalizers
}

# AIRM puts a finalizer on objects of many kinds:
# airm.silogen.ai/secret-finalizer on a Secret,
# airm.silogen.ai/storages-configmap-finalizer on a ConfigMap, and
# airm.silogen.ai/workloads-finalizer on the objects of a served model, which
# are the InferenceService, the HTTPRoute, the Service, the Pod and the
# ReplicaSet. These stop the demo namespace from draining. Only an object that
# carries an AIRM finalizer is changed, because these kinds also hold objects
# that belong to the cluster and not to AMD EAI. A kind whose CRD is already
# gone makes kubectl exit non-zero, which the trailing `|| true` absorbs.
strip_airm_core_finalizers() {
  local kind ns name fins
  for kind in secrets configmaps services pods replicasets deployments \
      inferenceservices httproutes; do
    kubectl get "${kind}" --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.finalizers}{"\n"}{end}' 2>/dev/null \
      | while IFS='|' read -r ns name fins; do
          [[ -z "${name}" ]] && continue
          [[ "${fins}" != *airm.silogen.ai* ]] && continue
          kubectl patch "${kind}" "${name}" --namespace "${ns}" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
            && echo "cleared the AIRM finalizer on ${kind} ${ns}/${name}"
        done || true
  done
  return 0
}

# Kueue owns kueue.x-k8s.io/resource-in-use. AIRM creates a ClusterQueue and a
# ResourceFlavor, and this script deletes the Kueue operator before the CRDs.
strip_kueue_finalizers() {
  strip_resource_finalizers clusterqueues
  strip_resource_finalizers resourceflavors
  strip_resource_finalizers localqueues
  strip_resource_finalizers workloads
}

helm_uninstall aiwb aiwb
helm_uninstall airm airm

strip_airm_namespace_finalizers
strip_airm_object_finalizers

helm_uninstall aiwb-infra-external-secrets aiwb
helm_uninstall airm-infra-external-secrets airm
helm_uninstall aiwb-infra-cnpg aiwb
helm_uninstall airm-infra-cnpg airm
helm_uninstall airm-infra-rabbitmq airm
helm_uninstall keycloak keycloak
helm_uninstall seaweedfs-config seaweedfs-instance
helm_uninstall seaweedfs-operator seaweedfs-operator
# The AIM engine owns the AIMService, the AIMArtifact and the catalog objects,
# and it puts a finalizer on them. Delete them while the engine still runs, or
# the delete of the aim.eai.amd.com CRDs blocks. An AIMArtifact owns the model
# cache PVC, so this also releases that PVC.
kdelete aimservices --all --all-namespaces
kdelete aimartifacts --all --all-namespaces
kdelete aimprofilecaches --all --all-namespaces
kdelete aimclustermodels --all
kdelete aimclustermodelsources --all
strip_resource_finalizers aimservices
strip_resource_finalizers aimartifacts
strip_resource_finalizers aimprofilecaches
# A served model leaves an InferenceService and an HTTPRoute that carry the AIRM
# workloads finalizer. Clear the finalizer first, or the delete does not return.
strip_airm_core_finalizers
strip_resource_finalizers inferenceservices
kdelete inferenceservices --all --all-namespaces
kdelete httproutes --all --all-namespaces
helm_uninstall aim-engine aim-system
helm_uninstall kaiwo kaiwo-system
helm_uninstall kserve kserve-system
helm_uninstall kserve-crd kserve-system
helm_uninstall kueue kueue-system
helm_uninstall kuberay-operator default
# The DeviceConfig starts the device plugin, the node labeller and the metrics
# exporter. Its controller holds a finalizer on it, and the amd-gpu-operator
# release owns that controller. Delete the object while the controller still
# runs, or the delete of the amd.com CRDs blocks.
kdelete deviceconfig gpu-operator --namespace kube-amd-gpu
strip_resource_finalizers deviceconfigs
helm_uninstall amd-gpu-operator kube-amd-gpu
kdelete clusterpolicy local-path-access-mode-mutation
helm_uninstall kyverno kyverno
helm_uninstall openbao cf-openbao
kdelete clustersecretstore openbao-secret-store

strip_airm_object_finalizers
strip_kueue_finalizers
helm_manifest kaiwo-crds oci://ghcr.io/silogen/kaiwo-crds-chart --version v0.2.1 \
  | kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" --filename - || true
kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" \
  --filename https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml || true
kdelete namespace otel-lgtm-stack cluster-auth

kdelete gateway https --namespace envoy-gateway-system
kdelete secret cluster-tls --namespace envoy-gateway-system
kdelete gatewayclass envoy-gateway

helm_manifest aim-engine-crds \
  oci://registry-1.docker.io/amdenterpriseai/aim-engine-crds-chart \
  --version 0.2.6 \
  | kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" --filename - || true

kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" \
  --filename https://github.com/rabbitmq/cluster-operator/releases/download/v2.15.0/cluster-operator.yml || true

helm_uninstall opentelemetry-operator opentelemetry-operator-system
helm_uninstall keda keda
helm_uninstall external-secrets external-secrets
helm_uninstall prometheus-crds prometheus-system
helm_uninstall envoy-gateway envoy-gateway-system
helm_uninstall cnpg-operator cnpg-system
helm_uninstall cert-manager cert-manager

helm show crds oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  | yaml_only \
  | kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" --filename - || true
kdelete mutatingwebhookconfiguration \
  envoy-gateway-topology-injector.envoy-gateway-system
kdelete clusterrole \
  envoy-gateway-gateway-helm-certgen:envoy-gateway-system
kdelete clusterrolebinding \
  envoy-gateway-gateway-helm-certgen:envoy-gateway-system

# Helm keeps a CRD that a chart ships in its crds/ directory. Remove the groups
# that the dependency scripts install, or the next install inherits stale CRDs.
for group in \
  'seaweed\.seaweedfs\.com' \
  'postgresql\.cnpg\.io' \
  'ray\.io' \
  'kueue\.x-k8s\.io' \
  'kmm\.sigs\.x-k8s\.io' \
  'nfd\.k8s-sigs\.io' \
  'amd\.com' \
  'external-secrets\.io' \
  'kyverno\.io' \
  'wgpolicyk8s\.io' \
  'kaiwo\.silogen\.ai' \
  'serving\.kserve\.io' \
  'gateway\.envoyproxy\.io' \
  'gateway\.networking\.k8s\.io' \
  'gateway\.networking\.x-k8s\.io' \
  'keda\.sh' ; do
  crds="$(kubectl get crd --output name 2>/dev/null | grep -E "${group}\$" || true)"
  [[ -n "${crds}" ]] && echo "${crds}" \
    | xargs --no-run-if-empty kubectl delete --ignore-not-found --timeout "${KUBECTL_TIMEOUT}" || true
done

# The namespace delete below drains each namespace. An object that still holds a
# finalizer stops its namespace in Terminating, so clear them one more time.
strip_airm_object_finalizers
strip_kueue_finalizers
strip_airm_namespace_finalizers

# AIRM creates the demo namespace for its demo project. The original list misses it.
kdelete namespace \
  airm aiwb aim-system keycloak demo \
  seaweedfs-instance seaweedfs-operator \
  kube-amd-gpu kaiwo-system kserve-system kueue-system \
  kyverno cf-openbao otel-lgtm-stack cluster-auth \
  cert-manager cnpg-system external-secrets keda \
  opentelemetry-operator-system prometheus-system envoy-gateway-system \
  rabbitmq-system appwrapper-system

# A namespace deleted above can acquire the finalizer again before AIRM stops.
strip_airm_namespace_finalizers
