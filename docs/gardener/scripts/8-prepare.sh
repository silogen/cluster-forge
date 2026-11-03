#!/usr/bin/env bash
#
# 8-prepare.sh -- make a Gardener cluster ready for AMD Enterprise AI.
#
# Each change is safe to make again. Run 8-preflight.sh first, and read
# docs/gardener/README.md for the reason behind each change.
#
# Usage:
#   ./8-prepare.sh --dry-run        show each change
#   ./8-prepare.sh                  make the changes
#   ./8-prepare.sh --gpu            also remove a single AMD device plugin,
#                                 which the demo profile needs and demo-cpu
#                                 does not
#
# Environment:
#   GARDEN_KUBECONFIG  kubeconfig of the Gardener API. Step 1 raises maxPods
#                      with it. Without it step 1 only reports.
#   SHOOT_NAME         name of the Shoot (default: the only one)
#   SHOOT_NAMESPACE    namespace of the Shoot (default garden)
#   WANT_MAX_PODS      maxPods to set (default 250)
#   NODE_SSH           ssh target with root on the node, for example
#                      root@10.0.0.10. Step 1 then corrects the node agent
#                      over ssh. Without it step 1 prints the commands.
#   EAI_IP_RANGE       addresses for a second MetalLB pool, for example
#                      10.0.0.21-10.0.0.22. Step 3 makes no pool when this is
#                      empty, because the Gardener pool usually serves every
#                      namespace already.
#   EAI_POOL_NAME      name of that pool (default eai-pool)

set -euo pipefail

DRY_RUN=0
WITH_GPU=0
GARDEN_KUBECONFIG="${GARDEN_KUBECONFIG:-}"
SHOOT_NAME="${SHOOT_NAME:-}"
SHOOT_NAMESPACE="${SHOOT_NAMESPACE:-garden}"
WANT_MAX_PODS="${WANT_MAX_PODS:-250}"
NODE_SSH="${NODE_SSH:-}"
EAI_IP_RANGE="${EAI_IP_RANGE:-}"
EAI_POOL_NAME="${EAI_POOL_NAME:-eai-pool}"

PROTECTED_NAMESPACES=(
  garden
  kube-system
  istio-system
  virtual-garden-istio-ingress
  metallb-system
  extension-provider-local
  extension-networking-calico
)

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --gpu)     WITH_GPU=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { echo "prepare: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Print the command in a dry run, run it otherwise.
run() {
  if (( DRY_RUN )); then
    note "would run: $*"
    return 0
  fi
  "$@"
}

# Same, for a command that reads a manifest on stdin.
apply_stdin() {
  local what=$1
  if (( DRY_RUN )); then
    note "would apply ${what}:"
    sed 's/^/      /'
    return 0
  fi
  kubectl apply --server-side --force-conflicts -f -
}

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"

# A Shoot resource means this is the Gardener API. The platform belongs in the
# cluster, so this would put every object where no kubelet reads it.
if kubectl get shoots.core.gardener.cloud -A >/dev/null 2>&1; then
  die "this kubeconfig speaks to the Gardener API, not to the cluster"
fi

(( DRY_RUN )) && note "dry run: nothing changes"

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$NODE" ]] || die "no node found"

# ---------------------------------------------------------------------------
step "1. Pod limit"

CAP_PODS="$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.pods}')"
PODS_NOW="$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
note "maxPods=${CAP_PODS}, ${PODS_NOW} in use, $((CAP_PODS - PODS_NOW)) free"

if (( CAP_PODS >= WANT_MAX_PODS )); then
  note "already ${CAP_PODS}, nothing to do"
elif [[ -z "$GARDEN_KUBECONFIG" ]]; then
  note "GARDEN_KUBECONFIG is empty, so this step only reports."
  note "maxPods lives in the Shoot. README.md section 4.1 gives both steps."
else
  POOL="$(kubectl get node "$NODE" \
    -o jsonpath='{.metadata.labels.worker\.gardener\.cloud/pool}')"
  [[ -n "$POOL" ]] || die "the node carries no worker.gardener.cloud/pool label"
  note "node ${NODE} is in worker pool ${POOL}"

  if [[ -z "$SHOOT_NAME" ]]; then
    SHOOT_NAME="$(kubectl --kubeconfig "$GARDEN_KUBECONFIG" \
      get shoot -n "$SHOOT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')"
  fi
  [[ -n "$SHOOT_NAME" ]] || die "no Shoot in namespace ${SHOOT_NAMESPACE}"
  note "shoot ${SHOOT_NAMESPACE}/${SHOOT_NAME}"

  # The pool value wins over the Shoot-wide value, so the patch must name the
  # pool of this node. The test operation stops a patch that would change the
  # wrong pool, because the index is a position and not a name.
  IDX="$(kubectl --kubeconfig "$GARDEN_KUBECONFIG" \
    get shoot "$SHOOT_NAME" -n "$SHOOT_NAMESPACE" \
    -o jsonpath="{range .spec.provider.workers[*]}{.name}{'\n'}{end}" \
    | grep -nx "$POOL" | cut -d: -f1)"
  [[ -n "$IDX" ]] || die "worker pool ${POOL} is not in the Shoot"
  IDX=$((IDX - 1))

  note "patching worker ${IDX} (${POOL}) to maxPods=${WANT_MAX_PODS}"
  run kubectl --kubeconfig "$GARDEN_KUBECONFIG" patch shoot "$SHOOT_NAME" \
    -n "$SHOOT_NAMESPACE" --type=json -p "[
      {\"op\":\"test\",\"path\":\"/spec/provider/workers/${IDX}/name\",\"value\":\"${POOL}\"},
      {\"op\":\"add\",\"path\":\"/spec/provider/workers/${IDX}/kubernetes\",
       \"value\":{\"kubelet\":{\"maxPods\":${WANT_MAX_PODS}}}}
    ]"

  # Gardener writes a new OperatingSystemConfig secret with a new name. A
  # usual cluster replaces the machine, and the new machine learns the name.
  # A self-hosted shoot replaces no machine, so the name must be corrected by
  # hand, in the node label and in the configuration file of the agent.
  note "waiting for the new OperatingSystemConfig secret"
  NEW_OSC=""
  for _ in $(seq 1 30); do
    (( DRY_RUN )) && break
    NEW_OSC="$(kubectl get secret -n kube-system -o name 2>/dev/null \
      | sed 's|^secret/||' | grep -x "gardener-node-agent-${POOL}-[a-f0-9]*" \
      | head -1 || true)"
    CUR="$(kubectl get node "$NODE" \
      -o jsonpath='{.metadata.labels.worker\.gardener\.cloud/gardener-node-agent-secret-name}')"
    [[ -n "$NEW_OSC" && "$NEW_OSC" != "$CUR" ]] && break
    sleep 10
  done

  if (( DRY_RUN )); then
    note "would then point the node agent at the new secret"
  elif [[ -z "$NEW_OSC" ]]; then
    note "no new secret appeared. Do step two by hand, README.md section 4.1."
  else
    note "new secret ${NEW_OSC}"
    run kubectl label node "$NODE" \
      "worker.gardener.cloud/gardener-node-agent-secret-name=${NEW_OSC}" --overwrite

    AGENT_FIX="sed -i 's|secretName: gardener-node-agent-${POOL}-.*|secretName: ${NEW_OSC}|' /var/lib/gardener-node-agent/config-v*.yaml && systemctl restart gardener-node-agent"
    if [[ -n "$NODE_SSH" ]]; then
      note "correcting the node agent over ssh on ${NODE_SSH}"
      run ssh "$NODE_SSH" "$AGENT_FIX"
      note "the kubelet restarts. The pods continue to run."
    else
      note "NODE_SSH is empty. Run this with root on the node:"
      note "  ${AGENT_FIX}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "2. Storage class named default"

# Several charts write the name "default" into a PVC. The class is needed by
# name, not by role. An existing class is never replaced: a cluster that has
# one already made a storage choice, and that choice is better than this one.
EXISTING_SC="$(kubectl get storageclass default -o jsonpath='{.provisioner}' 2>/dev/null || true)"
if [[ -n "$EXISTING_SC" ]]; then
  note "storage class default is present (${EXISTING_SC}), left alone"
else
  note "storage class default is absent, making one with rancher.io/local-path"
  apply_stdin "StorageClass/default" <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
fi

# The default-class mark is claimed only when no class holds it. Two classes
# with the mark is worse than none, because Kubernetes then breaks the tie by
# creation time.
DEFAULT_SC="$(kubectl get storageclass \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
  2>/dev/null | grep '=true$' | cut -d= -f1 || true)"
if [[ -z "$DEFAULT_SC" ]]; then
  note "no class is the cluster default, marking default"
  run kubectl patch storageclass default \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
else
  note "cluster default is ${DEFAULT_SC//$'\n'/ }, left alone"
fi

if [[ "$EXISTING_SC" == "rancher.io/local-path" ]]; then
  note "local-path gives ReadWriteOnce only. The default-cpu profile holds"
  note "kyverno-policies-storage-local-path, which corrects the requests."
fi

# ---------------------------------------------------------------------------
step "3. MetalLB addresses for Envoy Gateway"

if ! kubectl get namespace metallb-system >/dev/null 2>&1; then
  note "MetalLB is absent. Envoy Gateway gets no address."
  note "Gardener normally supplies MetalLB. Do not install a second copy."
elif [[ -z "$EAI_IP_RANGE" ]]; then
  note "EAI_IP_RANGE is empty, so no pool is made. This is usually correct:"
  note "a Gardener pool with no serviceAllocation serves every namespace."
  note "pools that exist now:"
  kubectl get ipaddresspool -A \
    -o jsonpath='{range .items[*]}{"      "}{.metadata.name}{" "}{.spec.addresses}{"\n"}{end}' \
    2>/dev/null || true
  note "8-preflight.sh counts the free addresses of each pool."
else
  note "adding pool ${EAI_POOL_NAME} with ${EAI_IP_RANGE}"
  note "the pool that Gardener made is not changed"
  apply_stdin "IPAddressPool/${EAI_POOL_NAME}" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${EAI_POOL_NAME}
  namespace: metallb-system
spec:
  addresses:
    - ${EAI_IP_RANGE}
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${EAI_POOL_NAME}
  namespace: metallb-system
spec:
  ipAddressPools:
    - ${EAI_POOL_NAME}
EOF
fi

# ---------------------------------------------------------------------------
step "4. Single AMD device plugin"

# The GPU operator starts its own device plugin from a DeviceConfig. Two
# plugins share one kubelet socket, and the GPU count then moves between 0
# and 1. A profile that ends with -cpu installs no operator, so a plugin that
# somebody installed by hand does no damage there.
mapfile -t DP_DAEMONSETS < <(kubectl get daemonset -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
  2>/dev/null | grep 'amdgpu-device-plugin' || true)

if (( ${#DP_DAEMONSETS[@]} == 0 )); then
  note "none present, nothing to do"
elif (( ! WITH_GPU )); then
  for entry in "${DP_DAEMONSETS[@]}"; do
    note "found DaemonSet ${entry// //}, left alone"
  done
  note "the demo-cpu profile installs no GPU operator, so this is correct."
  note "run with --gpu before the demo profile."
else
  for entry in "${DP_DAEMONSETS[@]}"; do
    read -r ns name <<<"$entry"
    note "found DaemonSet ${ns}/${name}"
    run kubectl delete daemonset "$name" -n "$ns" --ignore-not-found
  done
  note "the GPU is not visible until the GPU operator installs. This is correct."
fi

# ---------------------------------------------------------------------------
step "5. Mark the namespaces that Gardener owns"

# The label changes no behaviour. It tells a person which namespaces belong to
# the management plane, because a deletion in one of them stops Gardener, and
# on a self-hosted shoot it can also stop your own access.
for ns in "${PROTECTED_NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    run kubectl label namespace "$ns" gardener.cloud/protected=true --overwrite
  fi
done

printf '\n'
if (( DRY_RUN )); then
  echo "prepare: dry run finished, nothing changed."
else
  echo "prepare: finished. Run ./8-preflight.sh again."
fi
