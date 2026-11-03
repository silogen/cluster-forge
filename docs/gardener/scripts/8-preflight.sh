#!/usr/bin/env bash
#
# 8-preflight.sh -- report if a Gardener cluster can take AMD Enterprise AI.
#
# This script reads. It changes nothing. It prints one line for each check and
# exits 1 if a check fails. Read docs/gardener/README.md for the reason behind
# each check.
#
# Usage:
#   ./8-preflight.sh
#   PROFILE=demo ./8-preflight.sh      # the GPU profile
#
# Environment:
#   PROFILE            Spur profile to install (default demo-cpu). A name that
#                      ends with -cpu installs no GPU operator, so the check
#                      for a single device plugin is then a note, not a fault.
#   NEED_POD_SLOTS     free pod slots the platform needs (default 60)
#   NEED_LB_ADDRESSES  free LoadBalancer addresses needed (default 1)

set -uo pipefail

PROFILE="${PROFILE:-demo-cpu}"
NEED_POD_SLOTS="${NEED_POD_SLOTS:-60}"
NEED_LB_ADDRESSES="${NEED_LB_ADDRESSES:-1}"

case "$PROFILE" in
  *-cpu) WANTS_GPU_OPERATOR=0 ;;
  *)     WANTS_GPU_OPERATOR=1 ;;
esac

# Namespaces that Gardener owns. A platform namespace must not be one of them.
PROTECTED_NAMESPACES=(
  garden
  kube-system
  istio-system
  virtual-garden-istio-ingress
  metallb-system
  extension-provider-local
  extension-networking-calico
)

FAILED=0
WARNED=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARNED=$((WARNED + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=$((FAILED + 1)); }
note() { printf '        %s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }

printf 'preflight for profile %s\n' "$PROFILE"

head2 "Tools on this workstation"

for t in kubectl python3; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t is on PATH"
  else
    bad "$t is not on PATH"
  fi
done

# Spur builds its binary from the charts, so it needs these three as well.
for t in go helm just; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t is on PATH"
  else
    warn "$t is not on PATH. 'just all' in spur/ needs it."
  fi
done

head2 "Cluster connection"

if ! kubectl version -o json >/dev/null 2>&1; then
  bad "kubectl cannot reach a cluster. Set KUBECONFIG."
  echo
  echo "preflight stopped: no cluster."
  exit 1
fi

SERVER_VERSION="$(kubectl version -o json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"
ok "connected, Kubernetes ${SERVER_VERSION:-unknown}"

# The Gardener API serves Shoot. The cluster API does not. An installation into
# the Gardener API puts objects where no kubelet reads them.
if kubectl get shoots.core.gardener.cloud -A >/dev/null 2>&1; then
  bad "this kubeconfig speaks to the Gardener API, not to the cluster"
  echo
  echo "preflight stopped: wrong API. Read README.md section 1."
  exit 1
fi
ok "this kubeconfig speaks to the cluster API"

if kubectl get namespace garden >/dev/null 2>&1; then
  ok "namespace garden is present, so Gardener manages this cluster"
else
  warn "namespace garden is absent. This may not be a Gardener cluster."
fi

head2 "Node"

NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$NODE" ]]; then
  bad "no node found"
  echo
  echo "preflight stopped: no node."
  exit 1
fi
ok "${NODE_COUNT} node(s), first is ${NODE}"

READY="$(kubectl get node "$NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
if [[ "$READY" == "True" ]]; then
  ok "${NODE} is Ready"
else
  bad "${NODE} is not Ready"
fi

TAINTS="$(kubectl get node "$NODE" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null)"
if [[ -z "$TAINTS" ]]; then
  ok "${NODE} has no taint"
else
  warn "${NODE} has taint(s): ${TAINTS}. Charts need a toleration."
fi

head2 "Capacity"

CAP_CPU="$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)"
CAP_MEM="$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)"
CAP_PODS="$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.pods}' 2>/dev/null)"
PODS_NOW="$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
ok "capacity: cpu=${CAP_CPU} memory=${CAP_MEM} pods=${CAP_PODS}"
note "the scheduler reads these numbers, not the installed hardware"

if [[ -n "$CAP_PODS" ]]; then
  FREE_SLOTS=$((CAP_PODS - PODS_NOW))
  if (( FREE_SLOTS >= NEED_POD_SLOTS )); then
    ok "${FREE_SLOTS} free pod slots (${PODS_NOW} in use), ${NEED_POD_SLOTS} needed"
  else
    bad "${FREE_SLOTS} free pod slots (${PODS_NOW} in use), ${NEED_POD_SLOTS} needed"
    note "raise maxPods in the Shoot. README.md section 4.1."
  fi
fi

head2 "Node agent and the kubelet configuration"

# A self-hosted shoot replaces no machine, so the node agent keeps the secret
# name it started with. After a Shoot change that name is stale, the secret is
# gone, and the kubelet keeps its old configuration. README.md section 4.1.
WANTED_OSC="$(kubectl get node "$NODE" \
  -o jsonpath='{.metadata.labels.worker\.gardener\.cloud/gardener-node-agent-secret-name}' \
  2>/dev/null)"
if [[ -z "$WANTED_OSC" ]]; then
  warn "the node carries no gardener-node-agent-secret-name label"
elif kubectl get secret -n kube-system "$WANTED_OSC" >/dev/null 2>&1; then
  ok "node agent secret ${WANTED_OSC} is present"
else
  bad "node agent secret ${WANTED_OSC} does not exist"
  note "the node agent is stale and ignores Shoot changes."
  note "README.md section 4.1, step two."
fi

head2 "Storage"

SC_PROVISIONER="$(kubectl get storageclass default -o jsonpath='{.provisioner}' 2>/dev/null)"
if [[ -n "$SC_PROVISIONER" ]]; then
  ok "storage class default is present (${SC_PROVISIONER})"
else
  bad "no storage class named default. Several charts write that name."
fi

DEFAULT_SC="$(kubectl get storageclass \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
  2>/dev/null | grep '=true$' | cut -d= -f1 | tr '\n' ' ')"
case "$(printf '%s' "$DEFAULT_SC" | wc -w | tr -d ' ')" in
  0) warn "no storage class is the cluster default" ;;
  1) ok "cluster default storage class: ${DEFAULT_SC}" ;;
  *) warn "more than one default storage class: ${DEFAULT_SC}" ;;
esac

if [[ "$SC_PROVISIONER" == "rancher.io/local-path" ]]; then
  ok "local-path gives ReadWriteOnce only"
  note "the default-cpu profile holds kyverno-policies-storage-local-path,"
  note "which changes a ReadWriteMany request to ReadWriteOnce."
fi

head2 "Load balancer"

if kubectl get namespace metallb-system >/dev/null 2>&1; then
  ok "MetalLB is present. Do not install it again."
else
  warn "MetalLB is absent. Envoy Gateway needs a LoadBalancer address."
fi

# Count the addresses of every pool, and subtract the ones a Service holds.
# A pool with a serviceAllocation block does not serve every namespace, so the
# platform cannot rely on it.
LB_REPORT="$(python3 - <<'PY' 2>/dev/null
import ipaddress, json, subprocess, sys


def kget(args):
    out = subprocess.run(["kubectl", "get", *args, "-o", "json"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return {"items": []}
    return json.loads(out.stdout or '{"items":[]}')


pools = kget(["ipaddresspool", "-A"])["items"]
if not pools:
    print("WARN|MetalLB has no IPAddressPool")
    sys.exit(0)

used = set()
for svc in kget(["svc", "-A"])["items"]:
    for ing in (svc.get("status", {}).get("loadBalancer", {}).get("ingress") or []):
        if ing.get("ip"):
            used.add(ing["ip"])

free_open = 0
for p in pools:
    name = p["metadata"]["name"]
    spec = p.get("spec", {})
    addrs = []
    for a in spec.get("addresses", []):
        if "-" in a:
            lo, hi = a.split("-", 1)
            lo, hi = ipaddress.ip_address(lo.strip()), ipaddress.ip_address(hi.strip())
            addrs += [str(ipaddress.ip_address(i))
                      for i in range(int(lo), int(hi) + 1)]
        else:
            addrs += [str(h) for h in ipaddress.ip_network(a, strict=False)]
    free = [a for a in addrs if a not in used]
    restricted = "serviceAllocation" in spec
    print("OK|pool {}: {} address(es), {} free{}".format(
        name, len(addrs), len(free),
        ", restricted to selected namespaces" if restricted else ""))
    if free:
        print("NOTE|first free in {}: {}".format(name, free[0]))
    if not restricted:
        free_open += len(free)

print("COUNT|{}".format(free_open))
PY
)"

FREE_LB=0
while IFS='|' read -r kind text; do
  case "$kind" in
    OK)    ok "$text" ;;
    WARN)  warn "$text" ;;
    NOTE)  note "$text" ;;
    COUNT) FREE_LB="$text" ;;
    *)     [[ -n "$kind" ]] && note "$kind" ;;
  esac
done <<< "$LB_REPORT"

if (( FREE_LB >= NEED_LB_ADDRESSES )); then
  ok "${FREE_LB} free address(es) serve every namespace, ${NEED_LB_ADDRESSES} needed"
  note "no MetalLB change is necessary. README.md section 4.2."
else
  bad "${FREE_LB} free address(es) serve every namespace, ${NEED_LB_ADDRESSES} needed"
  note "add a second pool. README.md section 4.2."
fi

head2 "GPU"

GPU="$(kubectl get node "$NODE" \
  -o jsonpath='{.status.allocatable.amd\.com/gpu}' 2>/dev/null)"
if [[ -n "$GPU" ]]; then
  ok "node advertises amd.com/gpu=${GPU}"
else
  ok "node advertises no amd.com/gpu"
fi

if kubectl get daemonset -A -o name 2>/dev/null | grep -q 'amdgpu-device-plugin'; then
  if (( WANTS_GPU_OPERATOR )); then
    bad "a single AMD device plugin DaemonSet is present"
    note "profile ${PROFILE} installs the GPU operator, which starts its own."
    note "Two plugins share one socket. README.md section 4.4."
  else
    ok "a single AMD device plugin DaemonSet is present"
    note "profile ${PROFILE} installs no GPU operator, so this does no damage."
  fi
else
  ok "no single AMD device plugin DaemonSet"
fi

head2 "Namespaces that Gardener owns"

for ns in "${PROTECTED_NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    ok "${ns} is present. Do not install into it."
  fi
done

printf '\n'
if (( FAILED > 0 )); then
  printf 'preflight: %d failed, %d warnings. Correct the failures first.\n' \
    "$FAILED" "$WARNED"
  exit 1
fi
printf 'preflight: 0 failed, %d warnings. The cluster is ready.\n' "$WARNED"
