#!/bin/bash

# Remove what install.sh installs, one app at a time, in reverse order.
#
# The install order in root/values-openshift.yaml is a dependency order: CRDs before the
# controllers that watch them, the gateway before the routes that hang off it, secrets
# before the workloads that mount them. Walked backwards it is an uninstall order, so
# this script reads that same file and needs nothing added to it.
#
# What gets deleted is not a guess. install.sh is sourced as a library and its
# renderer is run again for each step, producing the same manifests that were applied;
# the objects named in them are what this script deletes. That is why the two scripts
# share the render functions rather than each having their own -- a chart's values decide
# which objects it emits and what they are called, so a second renderer that drifted
# would delete a different set of objects than the install created, and the difference
# would be silent.
#
# Everything a step declares is deleted, including the two kinds where deleting the object
# is also deleting data -- CustomResourceDefinition, which takes every custom resource of
# that type cluster-wide, and PersistentVolumeClaim/PersistentVolume, which take the
# volume. That is the point: a step is either off the cluster or it is not, and a run that
# left those behind could not answer which. --keep-crds and --keep-volumes are there for
# when it should.
#
# Namespaces are the exception and are only deleted with --namespaces. A namespace is not
# one step's to delete: openbao, openbao-config and openbao-init-job share cf-openbao, and
# taking it at the first of them would delete the other two along with anything else that
# has since moved in. It also cascades past this file entirely. The ones a walk has emptied
# and left standing are tracked in README.md, to be swept in one final pass.
#
# It is a dry run unless --delete is passed, so the first run of this on any cluster prints
# exactly what the real one would do.
#
# What a render cannot account for is everything the platform made after it was installed:
# the served models, the workspaces, the volumes those claimed, the secrets an operator
# generated. None of that is in any chart, so no step's inventory names it.
#
# The custom resources among them are deleted first, before the walk, while every
# controller is still up to run the finalizers they carry -- see THE RUNTIME, BEFORE ANY
# CONTROLLER GOES. What is left after that is the plain Kubernetes objects an operator
# created, which have no finalizers to strand and go with --namespaces.
#
# Usage:
#
#   KUBECONFIG=docs/openshift/kube.yaml ./docs/openshift/uninstall/uninstall-all.sh
#       Dry run over the whole order: what each step would delete, and what it would keep.
#
#   ... ./uninstall-all.sh --delete --step
#       The real thing, pausing for a yes before each step. This is the one to use while
#       finding out how a cluster comes apart.
#
#   ... ./uninstall-all.sh --delete routes aiwb
#       Only those two steps, in uninstall order.
#
#   ... ./uninstall-all.sh --delete --namespaces
#       Everything above plus each step's namespace: a teardown that also takes what the
#       platform created at runtime and no chart declares.
#
# The same environment that installed a cluster must be set here too. The values that
# vary per install -- PLUGGABLE_DB, PLUGGABLE_S3, CF_VERSION_* -- decide which steps ran
# and which chart version they ran from, and a step uninstalled from a different chart
# than it was installed with deletes a different set of objects.

set -euo pipefail

CF_START_EPOCH="$(date +%s)"

# ============================================================================
# THE INSTALLER, AS A LIBRARY
# ============================================================================
# Sourced with CF_LIB_ONLY=true, which stops it just before its install loop. Everything
# before that point defines a function or reads the cluster, so sourcing it changes
# nothing on the cluster; what it leaves behind is the release tarball unpacked, the
# environment discovered from the cluster (DOMAIN, the GPU namespace, the storage class,
# the AIWB project id), the app order in CF_APPS, and the renderer.
#
# Fetched from main when there is no copy next to this script, so that a piped run works
# the same way the installer's own piped run does.
CF_SETUP_URL="https://raw.githubusercontent.com/silogen/cluster-forge/refs/heads/main/docs/openshift/install.sh"

cf_locate_setup() {
  local here
  if [ -n "${CF_SETUP_SCRIPT:-}" ]; then
    printf '%s' "${CF_SETUP_SCRIPT}"
    return 0
  fi
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
    if [ -f "${here}/install.sh" ]; then
      printf '%s' "${here}/install.sh"
      return 0
    fi
    if [ -f "${here}/../install.sh" ]; then
      printf '%s' "${here}/../install.sh"
      return 0
    fi
  fi
  local staged
  staged="$(mktemp "${TMPDIR:-/tmp}/cf-setup-operator.XXXXXX.sh")"
  echo "ℹ️  No install.sh next to this script; fetching it from cluster-forge main..." >&2
  if ! curl -fsSL "${CF_SETUP_URL}" -o "${staged}"; then
    rm -f "${staged}"
    {
      echo "❌ Could not obtain install.sh, which this script reads the install"
      echo "   order and the renderer from."
      echo "   Tried: ${CF_SETUP_URL}"
      echo "   Run from a cluster-forge checkout, or set CF_SETUP_SCRIPT to a copy."
    } >&2
    exit 1
  fi
  printf '%s' "${staged}"
}

# ============================================================================
# OPTIONS
# ============================================================================
CF_DELETE=false          # --delete: actually delete, rather than print what would go
CF_STEP=false            # --step: confirm each step
CF_LIST=false            # --list: print the uninstall order and stop
CF_DRAIN=auto            # --drain forces on, --keep-runtime off; auto = whole-order runs
CF_DRAIN_TIMEOUT="${CF_DRAIN_TIMEOUT:-300}"  # seconds to wait for the drained objects to actually
                         # go; 0 deletes them and moves on without waiting
CF_KEEP_NAMESPACES=true  # --namespaces turns this off
CF_KEEP_CRDS=false       # --keep-crds turns this on
CF_KEEP_VOLUMES=false    # --keep-volumes turns this on
CF_FROM=""               # --from <app>: start here in the uninstall order
CF_UNTIL=""              # --until <app>: stop after this one
CF_ONLY=()               # positional app names: only these

# --skip / CF_SKIP: steps whose copy on this cluster is not this script's to remove, because
# it was changed or applied by hand. Deliberately not a field in values-openshift.yaml: that
# file says what an install does on every cluster, while what was done to one cluster by hand
# belongs to the invocation. An environment variable as well as a flag because a teardown is
# usually a long series of single-step runs, and `export CF_SKIP=...` once holds for all of
# them, where a flag has to be remembered every time -- and the time it is forgotten is the
# run that deletes the thing.
cf_skip_arg="${CF_SKIP:-}"
CF_SKIP=()

usage() {
  cat <<'EOF'
Usage: uninstall-all.sh [options] [app ...]

Walks root/values-openshift.yaml backwards and deletes what each step installed,
including its CRDs and volumes. Prints what it would delete and changes nothing
unless --delete is given.

  --delete            actually delete (default: dry run)
  --step              ask before each step: [y]es, [n]o to skip it, [q]uit
  --list              print the uninstall order and exit
  --drain             delete operator-created custom resources first, even on a partial
                      run (default: only when the run covers the whole order)
  --keep-runtime      skip that, and leave the served models, workspaces and caches
                      to whatever takes them later
                      CF_DRAIN_TIMEOUT sets how long the drain waits for finalizers
                      (default 300s; 0 deletes and moves on, for the case where a
                      controller keeps recreating what the drain removes)
  --from <app>        start at this app in the uninstall order
  --until <app>       stop after this app
  --skip <app,...>    leave these apps alone, for the ones this cluster had changed by
                      hand; repeatable, and read from CF_SKIP too, so exporting it once
                      covers a whole series of single-step runs
  --namespaces        also delete each step's namespace, which takes everything in it,
                      including what other steps and the platform put there
  --keep-crds         leave CustomResourceDefinitions alone (deleting one takes every
                      custom resource of that type, cluster-wide)
  --keep-volumes      leave PersistentVolumeClaims and PersistentVolumes alone
  -h, --help          this

Positional arguments name the only apps to act on, by their key in values-openshift.yaml.

Set the same PLUGGABLE_DB, PLUGGABLE_S3 and CF_VERSION_* values the install ran with:
they decide which steps exist and which chart version each one renders from.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --delete)          CF_DELETE=true ;;
    --step)            CF_STEP=true ;;
    --list)            CF_LIST=true ;;
    --drain)           CF_DRAIN=true ;;
    --keep-runtime)    CF_DRAIN=false ;;
    --namespaces)      CF_KEEP_NAMESPACES=false ;;
    --keep-crds)       CF_KEEP_CRDS=true ;;
    --keep-volumes)    CF_KEEP_VOLUMES=true ;;
    --from)            CF_FROM="${2:-}"; shift ;;
    --until)           CF_UNTIL="${2:-}"; shift ;;
    --skip)            cf_skip_arg="${cf_skip_arg} ${2:-}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "❌ unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                 CF_ONLY+=("$1") ;;
  esac
  shift
done

read -ra CF_SKIP <<< "${cf_skip_arg//,/ }"

CF_LIB_ONLY=true source "$(cf_locate_setup)"

# The order to walk. Reversed once, here, so everything below reads forwards.
CF_ORDER=()
for (( cf_i = ${#CF_APPS[@]} - 1; cf_i >= 0; cf_i-- )); do
  CF_ORDER+=("${CF_APPS[cf_i]}")
done

# An app named on the command line that is not in the file is a typo, and a typo that
# silently uninstalls nothing looks exactly like a step that was already clean.
for cf_want in ${CF_ONLY[@]+"${CF_ONLY[@]}"} ${CF_SKIP[@]+"${CF_SKIP[@]}"} \
               ${CF_FROM:+"${CF_FROM}"} ${CF_UNTIL:+"${CF_UNTIL}"}; do
  cf_found=false
  for cf_app in "${CF_ORDER[@]}"; do
    [ "${cf_app}" = "${cf_want}" ] && cf_found=true && break
  done
  if [ "${cf_found}" != true ]; then
    echo "❌ no app '${cf_want}' in $(basename "${CF_OPENSHIFT_VALUES}")" >&2
    echo "   --list prints the names." >&2
    exit 1
  fi
done

if [ "${CF_LIST}" = true ]; then
  echo ""
  echo "Uninstall order (${#CF_ORDER[@]} apps, reverse of the install order):"
  cf_n=0
  for cf_app in "${CF_ORDER[@]}"; do
    cf_n=$((cf_n + 1))
    cf_mark=""
    for cf_want in ${CF_SKIP[@]+"${CF_SKIP[@]}"}; do
      [ "${cf_want}" = "${cf_app}" ] && cf_mark="  ⏭️  skipped by request" && break
    done
    printf '  %2d. %-40s %-9s %s%s\n' "${cf_n}" "${cf_app}" \
      "$(app_field "${cf_app}" 'mode')" "$(app_field "${cf_app}" 'name')" "${cf_mark}"
  done
  exit 0
fi

# ============================================================================
# WHAT IS NOT DELETED
# ============================================================================
# kind_kept <kind> : true when the flags say to leave this kind alone.
kind_kept() {
  case "$1" in
    Namespace)                [ "${CF_KEEP_NAMESPACES}" = true ] ;;
    CustomResourceDefinition) [ "${CF_KEEP_CRDS}" = true ] ;;
    PersistentVolumeClaim|PersistentVolume)
                              [ "${CF_KEEP_VOLUMES}" = true ] ;;
    *)                        return 1 ;;
  esac
}

# namespace_kept <name> : true for a namespace that is not ours to delete even with
# --namespaces, with the reason in CF_KEEP_REASON.
#
# Deleting a namespace deletes everything in it, so the question is not whether this
# script created the namespace but whether anything else has since moved in. Two cases
# where something has:
#
# The platform's own namespaces, by name. The GPU operator is why: its namespace is
# discovered rather than fixed, and on a cluster where the operator came from the
# OpenShift catalogue that discovery returns openshift-amd-gpu, whose operator,
# subscription and CSV are not ours. local-path-storage is the same argument for storage:
# it holds the provisioner backing every PVC on the cluster, including volumes nothing
# here created -- see the custom step below, which declines it for that reason.
#
# And anything OLM installed into, by evidence. cluster-forge installs no operator through
# OLM, so a Subscription in one of these namespaces was created by an administrator or by
# the OpenShift console -- MetalLB and the GPU operator both turn up this way, in
# namespaces this script's own manifests also declare. Deleting the namespace would
# uninstall their operator as a side effect of removing ours.
CF_KEEP_REASON=""
namespace_kept() {
  local ns="$1"
  case "${ns}" in
    default|kube-*|openshift-*|local-path-storage)
      CF_KEEP_REASON="a platform namespace"
      return 0
      ;;
  esac
  if [ -n "$(kubectl get subscriptions.operators.coreos.com -n "${ns}" -o name 2>/dev/null)" ]; then
    CF_KEEP_REASON="an OLM-installed operator lives there"
    return 0
  fi
  return 1
}

# ============================================================================
# RESOURCE SCOPE
# ============================================================================
# Which kinds are namespaced, asked of the cluster's own discovery.
#
# A render does not say. `helm template` writes metadata.namespace on the objects that
# take one and leaves it off the rest, but so does a chart that simply forgot, and the
# manifests in extra/ are applied with --namespace for exactly that reason -- so the
# inventory fills the step's namespace in for anything that names none. That guess is
# right for a Deployment and wrong for a ClusterRole, and the wrong one reads as
# "ClusterRole/x in kserve-system", which is a namespace that has nothing to do with it.
declare -A CF_NAMESPACED=()
CF_SCOPES_LOADED=false
load_scopes() {
  local kind namespaced apiversion group
  [ "${CF_SCOPES_LOADED}" = true ] && return 0
  CF_SCOPES_LOADED=true
  while read -r kind namespaced apiversion; do
    [ -z "${kind}" ] && continue
    group="${apiversion%%/*}"
    [ "${group}" = "${apiversion}" ] && group=""
    CF_NAMESPACED["${kind}|${group}"]="${namespaced}"
  done < <(kubectl api-resources --no-headers 2>/dev/null \
    | awk '{print $NF, $(NF-1), $(NF-2)}')
}

# object_namespace <apiVersion> <kind> <namespace> : the namespace to address the object
# by, which is none when the kind does not take one.
#
# An unknown kind keeps whatever the inventory had: the CRD that defines it is already
# gone, so the object is gone with it and the delete will find nothing either way.
object_namespace() {
  local api="$1" kind="$2" ns="$3" group
  load_scopes
  group="${api%%/*}"
  [ "${group}" = "${api}" ] && group=""
  if [ "${CF_NAMESPACED["${kind}|${group}"]:-}" = "false" ]; then
    return 0
  fi
  printf '%s' "${ns}"
}

# ============================================================================
# OBJECT INVENTORY
# ============================================================================
# One object per line, as apiVersion|kind|name|namespace. Built by re-rendering the step
# and read back by the loop that deletes.

# emit_manifest <file> <default namespace> : the objects a manifest declares.
#
# The namespace falls back to the step's because that is what the apply did: kubectl was
# given --namespace for these files, and an object that names none was created there.
emit_manifest() {
  local file="$1" ns="$2"
  [ -s "${file}" ] || return 0
  yq -N "select(.kind != null and .kind != \"\") |
    [(.apiVersion // \"\"), .kind, (.metadata.name // \"\"),
     (.metadata.namespace // \"${ns}\")] | join(\"|\")" "${file}"
}

# emit_manifest_dir <dir> <recursive> <default namespace> : the same for a directory of
# plain YAML, which is what render: manifests applies.
emit_manifest_dir() {
  local dir="$1" recursive="$2" ns="$3" depth=() f
  [ "${recursive}" = "true" ] || depth=(-maxdepth 1)
  while IFS= read -r f; do
    emit_manifest "${f}" "${ns}"
  done < <(find "${dir}" "${depth[@]+${depth[@]}}" -type f \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort)
}

# collect_objects <app> : every object the step creates, one per line.
#
# Run in a subshell by the caller, for two reasons. The library's render functions exit
# on a chart that will not render or a file that cannot be fetched, and one step that
# cannot be rendered must not take the rest of the uninstall with it. And their progress
# output goes to stdout, which here is the inventory, so it is redirected wholesale.
collect_objects() {
  local app="$1" mode ns rendered dir file objects i name cm_ns
  mode="$(app_field "${app}" 'mode')"
  ns="$(app_namespace "${app}")"

  case "${mode}" in
    extra)
      file="$(stage_extra_file "${app}" 2>/dev/null)"
      emit_manifest "${file}" "${ns}"
      ;;
    core|external)
      if [ "${mode}" = external ]; then
        fetch_external_chart "${app}" >&2
      else
        resolve_chart_dir "${app}" >&2
      fi
      if [ "$(app_field "${app}" 'render')" = "manifests" ]; then
        dir="$(stage_manifest_dir "${app}" "${CF_CHART_DIR}" 2>/dev/null)"
        emit_manifest_dir "${dir}" "$(app_field "${app}" 'recursive')" "${ns}"
      else
        rendered="${CF_WORK_DIR}/${app}.uninstall.yaml"
        render_chart "${app}" "${CF_CHART_DIR}" "${CF_CHART_PATH}" "${rendered}" >&2
        emit_manifest "${rendered}" "${ns}"
      fi
      ;;
    objects)
      # No payload of its own: everything it creates is in the three blocks below.
      ;;
    custom)
      collect_custom_objects "${app}" "${ns}"
      ;;
    *)
      echo "❌ ${app}: unknown mode '${mode}'" >&2
      return 1
      ;;
  esac

  # Every mode can carry these, and each of them creates objects of its own.
  i=0
  while true; do
    name="$(yq -N ".apps.\"${app}\".configMaps[${i}].name // \"\"" "${CF_OPENSHIFT_VALUES}")"
    [ -z "${name}" ] && break
    cm_ns="$(expand_env_refs "${app}" \
      "$(yq -N ".apps.\"${app}\".configMaps[${i}].namespace // \"\"" "${CF_OPENSHIFT_VALUES}")")"
    printf 'v1|ConfigMap|%s|%s\n' "${name}" "${cm_ns:-${ns}}"
    i=$((i + 1))
  done

  objects="$(render_extra_objects "${app}" 2>/dev/null)"
  if [ -n "${objects}" ]; then
    file="${CF_WORK_DIR}/${app}.uninstall-extra-objects.yaml"
    printf '%s\n' "${objects}" > "${file}"
    emit_manifest "${file}" "${ns}"
  fi

  while read -r name; do
    [ -z "${name}" ] && continue
    file="${EXTRA_DIR}/${name}"
    ensure_extra_file "${file}" >&2
    emit_manifest "${file}" "${ns}"
  done < <(yq -N ".apps.\"${app}\".extraManifests[]? // \"\"" "${CF_OPENSHIFT_VALUES}")
}

# collect_custom_objects <app> <namespace> : the inverse of a custom handler, where there
# is one.
#
# mode: custom is the escape hatch for steps that are not expressible as data, so there is
# no general way to undo one. What there is, is the data each handler reads: a list of
# copies, a list of storage classes. Those name objects, and objects can be deleted. What
# is left over is the handlers whose work is not an object at all -- a patched ConfigMap,
# an SELinux label on a node, a rollout restart -- and those are reported rather than
# guessed at.
collect_custom_objects() {
  local app="$1" ns="$2" handler i resource to to_ns name
  handler="$(app_field "${app}" 'handler')"

  case "${handler}" in
    step_copy_objects)
      i=0
      while true; do
        resource="$(yq -N ".apps.\"${app}\".copies[${i}].resource // \"\"" "${CF_OPENSHIFT_VALUES}")"
        [ -z "${resource}" ] && break
        to="$(expand_env_refs "${app}" \
          "$(yq -N ".apps.\"${app}\".copies[${i}].to // \"\"" "${CF_OPENSHIFT_VALUES}")")"
        to_ns="$(expand_env_refs "${app}" \
          "$(yq -N ".apps.\"${app}\".copies[${i}].toNamespace // \"\"" "${CF_OPENSHIFT_VALUES}")")"
        # Only the copy goes. The original belongs to whichever step created it, and that
        # step is further back in this same order.
        printf '|%s|%s|%s\n' "${resource}" "${to}" "${to_ns:-${ns}}"
        i=$((i + 1))
      done
      ;;
    step_workspace_storageclasses)
      while read -r name; do
        [ -z "${name}" ] && continue
        printf 'storage.k8s.io/v1|StorageClass|%s|\n' "${name}"
      done < <(yq -N ".apps.\"${app}\".storageClasses[]? // \"\"" "${CF_OPENSHIFT_VALUES}")
      ;;
    step_local_path_storage)
      # Declined deliberately. This step installs the provisioner that backs every PVC on
      # the cluster and relabels a directory on every node for SELinux; the volumes that
      # exist now are the ones it provisioned, and the label is host state no manifest
      # describes. Removing it is a decision about the cluster's storage, not about
      # cluster-forge, so it is left to be made by hand.
      echo "ℹ️  ${app}: left in place — it owns the cluster's storage provisioner and node SELinux state" >&2
      ;;
    step_ai_gateway_webhook_probe)
      # Creates nothing: it waits for a webhook to answer and restarts a deployment.
      ;;
    *)
      echo "⚠️  ${app}: no uninstall known for handler ${handler} — nothing deleted for this step" >&2
      ;;
  esac
}

# ============================================================================
# DELETION
# ============================================================================
# resource_arg <apiVersion> <kind> : the kind.group form kubectl resolves unambiguously.
#
# Plain kinds collide: Policy, Cluster and Gateway each exist in more than one group on
# this cluster, and `kubectl delete cluster x` on a cluster running both CNPG and Cluster
# API is a question kubectl answers by picking one.
resource_arg() {
  local api="$1" kind="$2" group res
  res="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')"
  group="${api%%/*}"
  # copies: name a resource rather than a kind and carry no apiVersion, so there is
  # nothing to qualify with and the name is already what kubectl wants.
  [ -z "${api}" ] && { printf '%s' "${kind}"; return 0; }
  # The core group is spelled "v1", with no slash and no group name.
  [ "${group}" = "${api}" ] && { printf '%s' "${res}"; return 0; }
  printf '%s.%s' "${res}" "${group}"
}

CF_DELETED=0
CF_KEPT=0
CF_ABSENT=0
CF_FAILED=0

# object_exists <apiVersion> <kind> <name> <namespace> : whether the object is on the
# cluster now.
#
# Asked before every dry-run line, so that a dry run answers "what is left of this step"
# rather than "what does this step declare". The two are the same thing only on a cluster
# where nothing has been uninstalled yet, and the difference is the whole point of running
# a step, then running it again to see it come back empty.
object_exists() {
  local api="$1" kind="$2" name="$3" ns="$4" res
  local -a ns_args=()
  res="$(resource_arg "${api}" "${kind}")"
  [ -n "${ns}" ] && ns_args=(--namespace "${ns}")
  kubectl get "${res}" "${name}" "${ns_args[@]}" >/dev/null 2>&1
}

# delete_object <apiVersion> <kind> <name> <namespace> : delete one object, tolerating
# the two ways it can already be gone.
#
# Not found is the ordinary case on a re-run. A resource type the API server does not
# recognise is the other one: uninstalling in reverse order means a CRD may already have
# been deleted by a later-installed step, taking its custom resources with it, and the
# steps that created those resources are still to come.
delete_object() {
  local api="$1" kind="$2" name="$3" ns="$4" res out err rc=0
  local -a ns_args=()
  res="$(resource_arg "${api}" "${kind}")"
  [ -n "${ns}" ] && ns_args=(--namespace "${ns}")

  if [ "${CF_DELETE}" != true ]; then
    if object_exists "${api}" "${kind}" "${name}" "${ns}"; then
      printf '   would delete %s/%s%s\n' "${res}" "${name}" "${ns:+ in ${ns}}"
      CF_DELETED=$((CF_DELETED + 1))
    else
      CF_ABSENT=$((CF_ABSENT + 1))
    fi
    return 0
  fi

  # --wait=false throughout: a finalizer that never runs would otherwise hold the whole
  # uninstall at one object. What is still terminating is counted at the end of the step
  # instead, where it can be seen next to everything else that step deleted.
  #
  # stderr kept out of the answer: with --ignore-not-found, "did anything go" is exactly
  # "did kubectl print a line on stdout", and kubectl also writes deprecation warnings --
  # v1 Endpoints has one on this cluster -- which would otherwise read as a deletion of an
  # object that was never there.
  err="${CF_WORK_DIR}/uninstall-delete.err"
  out="$(kubectl delete "${res}" "${name}" "${ns_args[@]}" --ignore-not-found --wait=false \
    --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" 2>"${err}")" || rc=$?

  if [ "${rc}" -eq 0 ]; then
    if [ -z "${out}" ]; then
      CF_ABSENT=$((CF_ABSENT + 1))
    else
      printf '   🗑️  %s/%s%s\n' "${res}" "${name}" "${ns:+ in ${ns}}"
      CF_DELETED=$((CF_DELETED + 1))
    fi
    return 0
  fi

  out="$(cat "${err}")"
  case "${out}" in
    *'server doesn'*'have a resource type'*|*'the server could not find the requested resource'*|\
    *'NotFound'*|*'not found'*)
      CF_ABSENT=$((CF_ABSENT + 1))
      ;;
    *)
      printf '   ❌ %s/%s%s: %s\n' "${res}" "${name}" "${ns:+ in ${ns}}" "${out}" >&2
      CF_FAILED=$((CF_FAILED + 1))
      ;;
  esac
}

# still_present_group <resource> <namespace> <name> [<name>...]
#
# How many of the named objects are still on the cluster. Namespace is empty when the
# type is cluster-scoped. Names are fetched in batches of 25, the same size drain_runtime
# uses for discovery.
still_present_group() {
  local res="$1" ns="$2"
  shift 2
  local -a names=("$@") batch=() ns_args=() out n=0 i=0

  [ "${#names[@]}" -eq 0 ] && { printf '0'; return; }
  [ -n "${ns}" ] && ns_args=(--namespace "${ns}")

  while [ "${i}" -lt "${#names[@]}" ]; do
    batch=("${names[@]:i:25}")
    i=$((i + 25))
    out="$(kubectl get "${res}" "$(IFS=,; printf '%s' "${batch[*]}")" "${ns_args[@]}" \
      --ignore-not-found --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" \
      -o name 2>/dev/null || true)"
    [ -n "${out}" ] && n=$((n + $(printf '%s\n' "${out}" | grep -c .)))
  done
  printf '%s' "${n}"
}

# still_present <objects...> : how many of the objects just deleted are still there.
#
# Deleting without waiting means "deleted" only ever meant "accepted", and the difference
# matters here: a namespace stuck Terminating on a finalizer, or a custom resource whose
# controller has already been uninstalled and can no longer run its own, will sit there
# indefinitely and block the reinstall of that same step.
#
# Each line is apiVersion|Kind|name|namespace. Lines are sorted and grouped by resource
# type and namespace so one kubectl get covers many names, instead of one round trip each.
still_present() {
  local line api kind name ns res n=0 cur_res="" cur_ns=""
  local -a batch=() sorted

  [ $# -eq 0 ] && { printf '0'; return; }

  sorted="$(for line in "$@"; do
    IFS='|' read -r api kind name ns <<< "${line}"
    res="$(resource_arg "${api}" "${kind}")"
    printf '%s|%s|%s\n' "${res}" "${ns}" "${name}"
  done | LC_ALL=C sort -t'|' -k1,1 -k2,2)"

  while IFS='|' read -r res ns name; do
    [ -z "${name}" ] && continue
    if [ "${res}" != "${cur_res}" ] || [ "${ns}" != "${cur_ns}" ]; then
      if [ ${#batch[@]} -gt 0 ]; then
        n=$((n + $(still_present_group "${cur_res}" "${cur_ns}" "${batch[@]}")))
        batch=()
      fi
      cur_res="${res}"
      cur_ns="${ns}"
    fi
    batch+=("${name}")
  done <<< "${sorted}"

  if [ ${#batch[@]} -gt 0 ]; then
    n=$((n + $(still_present_group "${cur_res}" "${cur_ns}" "${batch[@]}")))
  fi
  printf '%s' "${n}"
}

# ============================================================================
# THE RUNTIME, BEFORE ANY CONTROLLER GOES
# ============================================================================
# Nothing in the walk deletes a custom resource an operator made at runtime -- the served
# models, the workspaces, the caches it filled. No chart declares them, so no step's
# inventory names them, and the only thing that would take them is the step that installed
# their CRD, which reverse order puts *after* the controller that serves them. By then the
# finalizers they carry have nobody left to run them, and the resource, its CRD and any
# namespace holding it all stop halfway through deleting.
#
# So they go first, while every controller is still up. That is also the only moment at
# which that is true of all of them at once: an InferenceService here holds one finalizer
# from KServe, uninstalled at step 29, and one from ai-gateway-discovery, uninstalled at
# step 8, and no step in the walk has both alive.
#
# The types to look at come from the same values file the walk reads: every step that
# installs CRDs verifies them by name, so this needs nothing added to it either. Minus the
# steps in --skip, whose CRDs are staying: draining a type whose step is not being touched
# would empty a component that is meant to keep running.
declared_crd_names() {
  CF_SKIP_LIST="${CF_SKIP[*]}" yq -N '
    (strenv(CF_SKIP_LIST) | split(" ")) as $skip
    | [ .apps | to_entries[]
        | select([.key] - $skip | length == 1)
        | .value.verify[]? | select(.resource == "crd") | (.name? , .names[]?) ]
    | .[] | select(. != null)' "${CF_OPENSHIFT_VALUES}" | sort -u
}

# ours <managers> : whether one of the writers on this object is an install applying it.
#
# Named exactly, not matched as kubectl*, because the difference between applying an object
# and touching one matters here: an AIMService the AIWB backend created (manager
# OpenAPI-Generator) and someone later annotated carries kubectl-annotate, and reading that
# as "an install step declared this" would leave the served model out of the drain and
# stranded. Creating verbs count, editing verbs do not.
ours() {
  local m
  local IFS=,
  for m in $1; do
    case "${m}" in
      cluster-forge/*|kubectl|kubectl-client-side-apply|kubectl-create|helm|helm-*)
        return 0 ;;
    esac
  done
  return 1
}

# guard_is_ours <app> : whether the object skipInstallWhenExists points at was applied by
# this install.
#
# The install asks "is something already here", and if so leaves its own copy uninstalled.
# The uninstall has to ask a different question -- whose copy is here -- and managedFields
# answers it, where mere existence cannot. The two answers differ inside one operator: the
# DeviceConfig on this cluster was applied by install.sh, so amd-gpu-operator-config has one
# of its own to delete, while the CRD it configures came from OLM, so amd-gpu-operator and
# amd-gpu-operator-crds have nothing of theirs and stay skipped.
#
# With a selector or no name, one match being ours is enough: it means this install applied
# its copy, and what gets deleted after that is still only what the step declares. The ones
# that are ours are left in CF_GUARD_OURS so the step can say whether its render accounts
# for them.
guard_is_ours() {
  local app="$1" resource name selector ns obj_name obj_ns managers rc=1
  local -a ns_args=() selector_args=()

  resource="$(app_field "${app}" 'skipInstallWhenExists.resource')"
  [ -z "${resource}" ] && return 1
  name="$(app_field "${app}" 'skipInstallWhenExists.name')"
  selector="$(expand_env_refs "${app}" "$(app_field "${app}" 'skipInstallWhenExists.selector')")"
  ns="$(expand_env_refs "${app}" "$(app_field "${app}" 'skipInstallWhenExists.namespace')")"
  [ -n "${ns}" ] && ns_args=(--namespace "${ns}")

  if [ -n "${name}" ]; then
    ours "$(kubectl get "${resource}" "${name}" "${ns_args[@]}" \
      -o jsonpath='{range .metadata.managedFields[*]}{.manager}{","}{end}' 2>/dev/null)" || return 1
    CF_GUARD_OURS+=("${name}|${ns}")
    return 0
  fi

  [ -z "${ns}" ] && ns_args=(--all-namespaces)
  [ -n "${selector}" ] && selector_args=(-l "${selector}")
  while IFS='|' read -r obj_name obj_ns managers; do
    [ -z "${obj_name}" ] && continue
    ours "${managers}" || continue
    CF_GUARD_OURS+=("${obj_name}|${obj_ns}")
    rc=0
  done < <(kubectl get "${resource}" "${selector_args[@]}" "${ns_args[@]}" \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.namespace}|{range .metadata.managedFields[*]}{.manager}{","}{end}{"\n"}{end}' 2>/dev/null)
  return "${rc}"
}

# drainable_types : the CRDs whose custom resources are this install's runtime, as
# name|apiVersion|kind lines.
#
# Two filters, and both are needed. The type has to be one this install put on the cluster:
# the values file declares monitoring.coreos.com and kmm.sigs.x-k8s.io CRDs, but on this
# cluster those were installed by cluster-version-operator and OLM, and their custom
# resources are OpenShift's own monitoring stack and GPU modules -- 39 objects that a drain
# filtered only by the resources' managers would happily delete. And the resource has to
# be one this install did *not* apply, which is the second filter, in the loop below: those
# belong to a step, and are left to it so that re-running a step still checks it.
drainable_types() {
  local -A declared=()
  local crd name scope group kind version managers
  while IFS= read -r crd; do
    [ -n "${crd}" ] && declared["${crd}"]=1
  done < <(declared_crd_names)

  while IFS='|' read -r name scope group kind version managers; do
    [ -z "${name}" ] && continue
    [ -n "${declared["${name}"]:-}" ] || continue
    ours "${managers}" || continue
    printf '%s|%s/%s|%s\n' "${name}" "${group}" "${version}" "${kind}"
  done < <(kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.scope}{"|"}{.spec.group}{"|"}{.spec.names.kind}{"|"}{range .spec.versions[?(@.storage==true)]}{.name}{end}{"|"}{range .metadata.managedFields[*]}{.manager}{","}{end}{"\n"}{end}' 2>/dev/null)
}

# drain_runtime : delete all of it, then wait for it to actually be gone.
#
# Waiting is the whole point. Deleting without waiting would hand the walk a cluster full
# of half-deleted resources and remove the controllers that were about to finish them.
# Whatever is still there when the wait runs out is named, with the finalizer holding it,
# because that is the one thing worth knowing before the controllers start going.
drain_runtime() {
  local line left crd api kind ns name managers
  local -a cf_drain=() cf_types=()

  echo ""
  echo "════════════════ [DRAIN] runtime custom resources ════════════════"

  # Asked for in batches rather than one type at a time: 86 declared CRDs against a cluster
  # this far away is minutes of round trips, and kubectl takes a comma-separated list.
  while IFS='|' read -r crd api kind; do
    [ -n "${crd}" ] && cf_types+=("${crd}")
  done < <(drainable_types)

  local -a batch=()
  local i=0
  while [ "${i}" -lt "${#cf_types[@]}" ]; do
    batch=("${cf_types[@]:i:25}")
    i=$((i + 25))
    while IFS='|' read -r api kind ns name managers; do
      [ -z "${name}" ] && continue
      ours "${managers}" && continue
      cf_drain+=("${api}|${kind}|${name}|${ns}")
    done < <(kubectl get "$(IFS=,; printf '%s' "${batch[*]}")" --all-namespaces --ignore-not-found \
      -o jsonpath='{range .items[*]}{.apiVersion}{"|"}{.kind}{"|"}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{range .metadata.managedFields[*]}{.manager}{","}{end}{"\n"}{end}' 2>/dev/null)
  done

  if [ "${#cf_drain[@]}" -eq 0 ]; then
    echo "   ✅ no operator-created custom resources left on the cluster"
    return 0
  fi

  for line in "${cf_drain[@]}"; do
    IFS='|' read -r cf_api cf_kind cf_name cf_ns <<< "${line}"
    delete_object "${cf_api}" "${cf_kind}" "${cf_name}" "${cf_ns}"
  done

  if [ "${CF_DELETE}" != true ]; then
    echo "   ${#cf_drain[@]} runtime object(s) would go before the walk starts"
    return 0
  fi

  if [ "${CF_DRAIN_TIMEOUT}" -le 0 ]; then
    echo "   ${#cf_drain[@]} runtime object(s) deleted; not waiting on finalizers (CF_DRAIN_TIMEOUT=0)"
    return 0
  fi

  # A wall-clock deadline, not a count of the sleeps: still_present batches its kubectl
  # calls by type and namespace, but each pass still costs seconds against a slow API.
  local started deadline
  started="$(date +%s)"
  deadline=$((started + CF_DRAIN_TIMEOUT))
  left="$(still_present "${cf_drain[@]}")"
  while [ "${left}" -gt 0 ] && [ "$(date +%s)" -lt "${deadline}" ]; do
    printf '\r   ⏳ %s of %s still finalizing (%ss)' "${left}" "${#cf_drain[@]}" \
      "$(( $(date +%s) - started ))"
    sleep 5
    left="$(still_present "${cf_drain[@]}")"
  done
  printf '\r%*s\r' 60 ''

  if [ "${left}" -eq 0 ]; then
    echo "   ✅ ${#cf_drain[@]} runtime object(s) gone, every finalizer ran"
    return 0
  fi

  echo "⚠️  ${left} object(s) did not finish deleting in ${CF_DRAIN_TIMEOUT}s. Their"
  echo "   controllers are still up now, but the walk below removes them, and after that"
  echo "   these can only be cleared by editing the finalizers out by hand:"
  for line in "${cf_drain[@]}"; do
    IFS='|' read -r cf_api cf_kind cf_name cf_ns <<< "${line}"
    object_exists "${cf_api}" "${cf_kind}" "${cf_name}" "${cf_ns}" || continue
    printf '   %s/%s%s — %s\n' "$(resource_arg "${cf_api}" "${cf_kind}")" "${cf_name}" \
      "${cf_ns:+ in ${cf_ns}}" \
      "$(kubectl get "$(resource_arg "${cf_api}" "${cf_kind}")" "${cf_name}" ${cf_ns:+--namespace "${cf_ns}"} \
         -o jsonpath='{.metadata.finalizers}' 2>/dev/null)"
  done
}

# ask <prompt> : y / n / q from the terminal, for --step.
#
# Read from /dev/tty rather than stdin, so that a piped run of this script (curl | bash)
# still prompts instead of eating the script itself as the answer.
ask() {
  local reply
  if [ ! -r /dev/tty ]; then
    echo "❌ --step needs a terminal to ask on, and there is none" >&2
    exit 1
  fi
  while true; do
    printf '%s [y/n/q] ' "$1" > /dev/tty
    read -r reply < /dev/tty || reply=q
    case "${reply}" in
      y|Y|yes) return 0 ;;
      n|N|no)  return 1 ;;
      q|Q|quit)
        echo "🛑 stopped at your request"
        exit 0
        ;;
    esac
  done
}

# ============================================================================
# UNINSTALL LOOP
# ============================================================================
# auto: drain only when the run covers the whole order, since that is when "delete the
# runtime first" is what was asked for. A run aimed at one step is aimed at one step, and
# clearing the whole cluster's runtime on the way would be a surprise; --drain asks for it.
if [ "${CF_DRAIN}" = auto ]; then
  if [ "${#CF_ONLY[@]}" -eq 0 ] && [ -z "${CF_FROM}" ]; then
    CF_DRAIN=true
  else
    CF_DRAIN=false
    CF_DRAIN_NOTE="Runtime custom resources left alone on a partial run; --drain includes them."
  fi
fi

echo ""
if [ "${CF_DELETE}" = true ]; then
  echo "🔥 Deleting ${#CF_ORDER[@]} apps in reverse install order from $(kubectl config current-context 2>/dev/null || echo 'the current context')"
  echo "   CRDs: $([ "${CF_KEEP_CRDS}" = true ] && echo kept || echo DELETED)" \
       "| volumes: $([ "${CF_KEEP_VOLUMES}" = true ] && echo kept || echo DELETED)" \
       "| namespaces: $([ "${CF_KEEP_NAMESPACES}" = true ] && echo kept || echo DELETED)" \
       "| runtime: $([ "${CF_DRAIN}" = false ] && echo kept || echo 'DELETED first')"
else
  echo "👀 Dry run over ${#CF_ORDER[@]} apps in reverse install order. Nothing will be deleted."
  echo "   Add --delete to carry it out, --step to be asked before each one."
fi

[ "${#CF_SKIP[@]}" -gt 0 ] && echo "   Skipped by request: ${CF_SKIP[*]}"
[ -n "${CF_DRAIN_NOTE:-}" ] && echo "   ${CF_DRAIN_NOTE}"
[ "${CF_DRAIN}" = true ] && drain_runtime

cf_started=true
[ -n "${CF_FROM}" ] && cf_started=false
cf_index=0
cf_steps_done=0
cf_steps_skipped=0

# The renderer explains what it leaves out of a step -- Helm hooks, kinds another step owns.
# Worth reading for a step that is about to delete something, noise for one that turns out to
# have nothing of its own, and which of the two it is is only known after the render. So the
# render's commentary is held here and printed once that is settled.
cf_notices="$(mktemp "${TMPDIR:-/tmp}/cf-uninstall-notices.XXXXXX")"
trap 'rm -f "${cf_notices}"' EXIT

for app in "${CF_ORDER[@]}"; do
  cf_index=$((cf_index + 1))
  app_name="$(app_field "${app}" 'name')"
  app_name="${app_name:-${app}}"

  # --from: everything before it in the uninstall order has been dealt with already.
  if [ "${cf_started}" != true ]; then
    [ "${app}" = "${CF_FROM}" ] && cf_started=true || continue
  fi

  # Named apps only, when any were named.
  if [ "${#CF_ONLY[@]}" -gt 0 ]; then
    cf_wanted=false
    for cf_want in "${CF_ONLY[@]}"; do
      [ "${cf_want}" = "${app}" ] && cf_wanted=true && break
    done
    [ "${cf_wanted}" = true ] || continue
  fi

  # --skip wins over being named on the command line: the point of exporting CF_SKIP for a
  # teardown is that the one run where it is forgotten is the one that deletes the step.
  cf_skip_this=false
  for cf_want in ${CF_SKIP[@]+"${CF_SKIP[@]}"}; do
    [ "${cf_want}" = "${app}" ] && cf_skip_this=true && break
  done
  if [ "${cf_skip_this}" = true ]; then
    echo ""
    echo "⏭️  ${app_name}: skipped by request (${app} is in --skip)"
    cf_steps_skipped=$((cf_steps_skipped + 1))
    continue
  fi

  # skipWhen: read exactly as the install reads it. An app that this deployment shape
  # never installs is not one this deployment shape can delete: the PLUGGABLE_DB=true
  # cluster has no in-cluster Keycloak database to remove.
  app_skip_when="$(app_field "${app}" 'skipWhen')"
  if [ -n "${app_skip_when}" ]; then
    skip_var="${app_skip_when%%=*}"
    skip_val="${app_skip_when#*=}"
    if [ "${!skip_var:-}" = "${skip_val}" ]; then
      echo ""
      echo "⏭️  ${app_name}: not installed in this shape, ${skip_var}=${skip_val}"
      cf_steps_skipped=$((cf_steps_skipped + 1))
      continue
    fi
  fi

  if [ "${app}" = "aim-cluster-model-source" ]; then
    discover_aim_hardware_families
    if [ -z "${CF_AIM_HARDWARE_FAMILIES:-}" ]; then
      echo ""
      echo "⏭️  ${app_name}: skipped — no amd.com/gpu.product-name labels matching Instinct or Radeon found on any node"
      cf_steps_skipped=$((cf_steps_skipped + 1))
      continue
    fi
  fi

  echo ""
  echo "════════════════ [UNDO ${cf_index}/${#CF_ORDER[@]}] ${app_name} ════════════════"

  cf_rc=0
  cf_inventory="$(collect_objects "${app}" 2>"${cf_notices}")" || cf_rc=$?
  if [ "${cf_rc}" -ne 0 ]; then
    cat "${cf_notices}" >&2
    echo "⚠️  ${app}: could not work out what it installed (rc=${cf_rc}) — skipped, nothing deleted" >&2
    cf_steps_skipped=$((cf_steps_skipped + 1))
    continue
  fi

  # Deduplicated because a step can name the same object twice and it only has to be
  # deleted once: aiwb-infra declares the namespaces it creates as extraObjects, and one
  # of them is also its own namespace: field, which --namespaces adds below.
  cf_objects=()
  unset cf_seen; declare -A cf_seen=()
  unset cf_by_name; declare -A cf_by_name=()
  while IFS= read -r cf_line; do
    [ -z "${cf_line}" ] && continue
    IFS='|' read -r cf_api cf_kind cf_name cf_ns <<< "${cf_line}"
    cf_ns="$(object_namespace "${cf_api}" "${cf_kind}" "${cf_ns}")"
    cf_line="${cf_api}|${cf_kind}|${cf_name}|${cf_ns}"
    [ -n "${cf_seen["${cf_line}"]:-}" ] && continue
    cf_seen["${cf_line}"]=1
    cf_by_name["${cf_name}|${cf_ns}"]=1
    cf_objects+=("${cf_line}")
  done <<< "${cf_inventory}"

  # The namespaces are not in any render: the install creates them with `kubectl create
  # namespace` before applying, so they only exist as the entry's namespace: field. Added
  # last so that everything inside is deleted first, which is also the order that makes a
  # stuck namespace legible -- what is left holding it is then whatever has a finalizer,
  # not everything that happened to be in there.
  if [ "${CF_KEEP_NAMESPACES}" != true ]; then
    cf_ns="$(app_namespace "${app}")"
    if [ -n "${cf_ns}" ] && [ -z "${cf_seen["v1|Namespace|${cf_ns}|"]:-}" ]; then
      cf_objects+=("v1|Namespace|${cf_ns}|")
    fi
  fi

  # skipInstallWhenExists: the step declares that if this object is already on the cluster,
  # the payload belongs to whoever put it there and the install leaves its own copy
  # uninstalled. Read backwards, existence is the wrong question: it says nothing about whose
  # copy is here, and both wrong answers do damage -- deleting what the platform installed,
  # or skipping what this install did and leaving the step half up. Two things have to hold
  # for what the guard found to be the step's, and neither is enough on its own.
  #
  # The field managers have to say this install applied it, or it belongs to OLM or the
  # cluster-version-operator, as the CRDs behind amd-gpu-operator-crds and prometheus-crds
  # do -- even though each of those steps renders that same CRD itself.
  #
  # And the step's render has to name it, because `kubectl apply` by hand is
  # indistinguishable from `kubectl apply` by the installer. amd-gpu-operator-config is the
  # case that needs this half: the DeviceConfig on the cluster was applied by hand as
  # test-deviceconfig, the chart names its own gpu-operator, and no gpu-operator exists --
  # so the step installed nothing here and has nothing to take away.
  CF_GUARD_OURS=()
  if install_already_provided "${app}"; then
    cf_guard_ours=false
    guard_is_ours "${app}" && cf_guard_ours=true
    cf_guard_owned=""
    for cf_guard in "${CF_GUARD_OURS[@]}"; do
      [ -n "${cf_by_name["${cf_guard}"]:-}" ] || continue
      cf_guard_owned="${cf_guard}"
      break
    done
    if [ "${cf_guard_ours}" != true ]; then
      echo "🔒 ${CF_SKIP_REASON} is present and this install did not apply it — nothing deleted for this step"
      cf_steps_skipped=$((cf_steps_skipped + 1))
      continue
    elif [ -z "${cf_guard_owned}" ]; then
      cf_guard="${CF_GUARD_OURS[0]}"
      cf_ns="${cf_guard#*|}"
      echo "🔒 ${CF_SKIP_REASON} was applied with kubectl, but as ${cf_guard%%|*}${cf_ns:+ in ${cf_ns}}, which this step does not declare — nothing deleted for this step"
      cf_steps_skipped=$((cf_steps_skipped + 1))
      continue
    fi
    echo "🔓 ${CF_SKIP_REASON} is present and is this step's own — carrying on"
  fi

  cat "${cf_notices}" >&2

  if [ "${#cf_objects[@]}" -eq 0 ]; then
    echo "   nothing to delete"
    cf_steps_done=$((cf_steps_done + 1))
    continue
  fi

  # A patch has no inverse: what the field was before is not recorded anywhere. The ones
  # aimed at an object this step also deletes are moot, since the object goes and takes the
  # patched field with it. Only the rest are worth reporting -- they changed something
  # another step or the platform owns, and outlive this uninstall, which is why a step can
  # come back subtly different after a reinstall.
  cf_patches="$(yq -N ".apps.\"${app}\".patches | length" "${CF_OPENSHIFT_VALUES}")"
  case "${cf_patches}" in ''|null|0) ;; *)
    cf_patches_foreign=0
    for (( cf_p = 0; cf_p < cf_patches; cf_p++ )); do
      cf_patch_name="$(yq -N ".apps.\"${app}\".patches[${cf_p}].name // \"\"" "${CF_OPENSHIFT_VALUES}")"
      cf_patch_ns="$(yq -N ".apps.\"${app}\".patches[${cf_p}].namespace // \"\"" "${CF_OPENSHIFT_VALUES}")"
      [ -z "${cf_patch_ns}" ] && cf_patch_ns="$(app_namespace "${app}")"
      [ -n "${cf_by_name["${cf_patch_name}|${cf_patch_ns}"]:-}" ] && continue
      cf_patches_foreign=$((cf_patches_foreign + 1))
    done
    if [ "${cf_patches_foreign}" -gt 0 ]; then
      echo "ℹ️  ${cf_patches_foreign} of ${cf_patches} patch(es) this step made are not undone — they modified objects it did not create"
    fi
    ;;
  esac

  if [ "${CF_STEP}" = true ]; then
    echo "   ${#cf_objects[@]} object(s):"
    for cf_line in "${cf_objects[@]}"; do
      IFS='|' read -r cf_api cf_kind cf_name cf_ns <<< "${cf_line}"
      if kind_kept "${cf_kind}"; then
        printf '     🔒 %s/%s%s\n' "${cf_kind}" "${cf_name}" "${cf_ns:+ in ${cf_ns}}"
      else
        printf '     •  %s/%s%s\n' "${cf_kind}" "${cf_name}" "${cf_ns:+ in ${cf_ns}}"
      fi
    done
    if ! ask "   Delete this step?"; then
      echo "   skipped"
      cf_steps_skipped=$((cf_steps_skipped + 1))
      continue
    fi
  fi

  cf_deleted_here=()
  cf_kept_here=0
  cf_before="${CF_DELETED}"
  cf_gone_before="${CF_ABSENT}"
  for cf_line in "${cf_objects[@]}"; do
    IFS='|' read -r cf_api cf_kind cf_name cf_ns <<< "${cf_line}"
    [ -z "${cf_name}" ] && continue
    if kind_kept "${cf_kind}"; then
      cf_kept_here=$((cf_kept_here + 1))
      CF_KEPT=$((CF_KEPT + 1))
      continue
    fi
    if [ "${cf_kind}" = Namespace ] && namespace_kept "${cf_name}"; then
      echo "   🔒 namespace ${cf_name} kept: ${CF_KEEP_REASON}"
      CF_KEPT=$((CF_KEPT + 1))
      continue
    fi
    delete_object "${cf_api}" "${cf_kind}" "${cf_name}" "${cf_ns}"
    cf_deleted_here+=("${cf_line}")
  done

  if [ "${cf_kept_here}" -gt 0 ]; then
    echo "   🔒 ${cf_kept_here} kept by the flags in use (see --help)"
  fi

  # The verdict on the step, which is what a re-run is for: a step whose objects are all
  # gone says so in one line, and one that still has some says how many.
  cf_here=$((CF_DELETED - cf_before))
  cf_gone_here=$((CF_ABSENT - cf_gone_before))
  if [ "${CF_DELETE}" = true ]; then
    if [ "${#cf_deleted_here[@]}" -gt 0 ]; then
      cf_left="$(still_present ${cf_deleted_here[@]+"${cf_deleted_here[@]}"})"
      if [ "${cf_left}" != "0" ]; then
        echo "   ⏳ ${cf_left} of ${#cf_deleted_here[@]} still there — deletion is asynchronous, or a finalizer is holding them"
      else
        echo "   ✅ nothing this step declares is left on the cluster"
      fi
    fi
  elif [ "${cf_here}" -eq 0 ] && [ "${cf_gone_here}" -gt 0 ]; then
    echo "   ✅ nothing this step declares is left on the cluster (${cf_gone_here} already gone)"
  elif [ "${cf_gone_here}" -gt 0 ]; then
    echo "   ${cf_here} still on the cluster, ${cf_gone_here} already gone"
  fi
  cf_steps_done=$((cf_steps_done + 1))
done

echo ""
if [ "${CF_DELETE}" = true ]; then
  echo "✅ ${cf_steps_done} step(s) uninstalled, ${cf_steps_skipped} skipped"
  echo "   ${CF_DELETED} deleted, ${CF_ABSENT} already gone, ${CF_KEPT} kept, ${CF_FAILED} failed"
else
  echo "👀 Dry run over ${cf_steps_done} step(s), ${cf_steps_skipped} skipped"
  echo "   ${CF_DELETED} object(s) would be deleted, ${CF_KEPT} kept"
fi
cf_print_elapsed
[ "${CF_DELETE}" = true ] && [ "${CF_FAILED}" -gt 0 ] && exit 1
exit 0
