#!/bin/bash

# Build local images from source and load them into a Kind cluster
#
# Usage:
#   ./build-local-images.sh [OPTIONS] [IMAGE_NAMES...]
#
# Options:
#   -s, --source-repo PATH     Path to silogen-core/core repository (default: auto-detect)
#   -c, --cluster-name NAME    Kind cluster name (default: cluster-forge-local)
#   -v, --values-file PATH     Path to values YAML for app detection (default: root/values_local_kind.yaml)
#   -l, --list                 List available images and exit
#   -n, --no-load              Build only, don't load into Kind
#   --no-cache                 Build with --no-cache flag
#   -h, --help                 Show this help message
#
# Arguments:
#   IMAGE_NAMES                Space-separated image names to build (default: all enabled)
#                              Available: airm-api, airm-agent, airm-ui, aiwb-api, aiwb-ui
#
# Examples:
#   ./build-local-images.sh                              # Build all enabled images
#   ./build-local-images.sh aiwb-api                     # Build only aiwb-api
#   ./build-local-images.sh aiwb-api aiwb-ui             # Build specific images
#   ./build-local-images.sh --no-cache aiwb-ui           # Rebuild without cache
#   ./build-local-images.sh -s ~/code/core --list        # List images using specific repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"

# Defaults
SOURCE_REPO=""
CLUSTER_NAME="cluster-forge-local"
VALUES_FILE="${ROOT_DIR}/root/values_local_kind.yaml"
LIST_ONLY=0
LOAD_INTO_KIND=1
DOCKER_NO_CACHE=""
REQUESTED_IMAGES=()

show_help() {
    sed -n '3,30p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-repo)
            SOURCE_REPO="$2"
            shift 2
            ;;
        -c|--cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -v|--values-file)
            VALUES_FILE="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=1
            shift
            ;;
        -n|--no-load)
            LOAD_INTO_KIND=0
            shift
            ;;
        --no-cache)
            DOCKER_NO_CACHE="--no-cache"
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
        *)
            REQUESTED_IMAGES+=("$1")
            shift
            ;;
    esac
done

# Auto-detect source repo path
if [ -z "${SOURCE_REPO}" ]; then
    for candidate in \
        "${ROOT_DIR}/../core" \
        "${ROOT_DIR}/../silogen-core" \
        "${ROOT_DIR}/../../core" \
        "${ROOT_DIR}/../../silogen-core"; do
        if [ -d "${candidate}" ]; then
            SOURCE_REPO="$(cd "${candidate}" && pwd)"
            break
        fi
    done
fi

if [ -z "${SOURCE_REPO}" ] || [ ! -d "${SOURCE_REPO}" ]; then
    echo "Error: Source repository not found."
    echo "Tried: ../core, ../silogen-core, ../../core, ../../silogen-core"
    echo "Use --source-repo PATH to specify the location"
    exit 1
fi

# Image registry: NAME|DOCKER_TAG|DOCKERFILE|BUILD_CONTEXT|APP_FLAG|K8S_DEPLOYMENTS
# APP_FLAG is what to grep for in values to determine if the image is needed
# K8S_DEPLOYMENTS is a comma-separated list of namespace/deployment to restart after build
declare -a IMAGE_REGISTRY=(
    "airm-api|amdenterpriseai/airm-api:local|${SOURCE_REPO}/services/airm/docker/api.Dockerfile|${SOURCE_REPO}|airm|airm/airm-api"
    "airm-agent|ghcr.io/silogen/core/airm-agent:local|${SOURCE_REPO}/services/airm/docker/agent.Dockerfile|${SOURCE_REPO}|airm|airm/airm-agent,airm/airm-agent-webhook"
    "airm-ui|amdenterpriseai/airm-ui:local|${SOURCE_REPO}/services/airm/docker/ui.Dockerfile|${SOURCE_REPO}/services/airm/ui|airm|airm/airm-ui"
    "aiwb-api|aiwb-api:local|${SOURCE_REPO}/apps/api/aiwb/Dockerfile|${SOURCE_REPO}|aiwb|aiwb/aiwb-api"
    "aiwb-ui|aiwb-ui:local|${SOURCE_REPO}/apps/ui/aiwb/Dockerfile|${SOURCE_REPO}/apps/ui|aiwb|aiwb/aiwb-ui"
)

is_app_enabled() {
    local app="$1"
    grep -qE "^\s+- ${app}\b" "${VALUES_FILE}" 2>/dev/null
}

# Determine which images to build
resolve_images() {
    local images=()

    if [ ${#REQUESTED_IMAGES[@]} -gt 0 ]; then
        for req in "${REQUESTED_IMAGES[@]}"; do
            local found=0
            for spec in "${IMAGE_REGISTRY[@]}"; do
                IFS='|' read -r name _ _ _ _ <<< "${spec}"
                if [ "${name}" = "${req}" ]; then
                    images+=("${spec}")
                    found=1
                    break
                fi
            done
            if [ "${found}" = "0" ]; then
                echo "Unknown image: ${req}"
                echo "Available images: $(printf '%s\n' "${IMAGE_REGISTRY[@]}" | cut -d'|' -f1 | tr '\n' ' ')"
                exit 1
            fi
        done
    else
        for spec in "${IMAGE_REGISTRY[@]}"; do
            IFS='|' read -r name _ _ _ app_flag <<< "${spec}"
            if is_app_enabled "${app_flag}"; then
                images+=("${spec}")
            fi
        done
    fi

    printf '%s\n' "${images[@]}"
}

list_images() {
    echo "Available images:"
    echo ""
    printf "  %-15s %-40s %s\n" "NAME" "DOCKER TAG" "STATUS"
    printf "  %-15s %-40s %s\n" "----" "----------" "------"
    for spec in "${IMAGE_REGISTRY[@]}"; do
        IFS='|' read -r name tag dockerfile _ app_flag <<< "${spec}"
        local status=""
        if is_app_enabled "${app_flag}"; then
            status="enabled"
        else
            status="disabled (${app_flag} not in enabledApps)"
        fi
        if [ ! -f "${dockerfile}" ]; then
            status="${status} [Dockerfile missing]"
        fi
        printf "  %-15s %-40s %s\n" "${name}" "${tag}" "${status}"
    done
    echo ""
    echo "Source repo: ${SOURCE_REPO}"
    echo "Values file: ${VALUES_FILE}"
}

if [ "${LIST_ONLY}" = "1" ]; then
    list_images
    exit 0
fi

IMAGES_TO_BUILD=$(resolve_images)

if [ -z "${IMAGES_TO_BUILD}" ]; then
    echo "No images to build."
    echo "Neither airm nor aiwb is enabled in ${VALUES_FILE}."
    echo "Use --list to see available images, or specify image names directly."
    exit 0
fi

IMAGE_COUNT=$(echo "${IMAGES_TO_BUILD}" | wc -l)
echo "Building ${IMAGE_COUNT} image(s) from: ${SOURCE_REPO}"
echo ""

LOG_DIR=$(mktemp -d)
trap "rm -rf ${LOG_DIR}" EXIT

BUILT=0
FAILED=0
FAILED_NAMES=()
DEPLOYMENTS_TO_RESTART=()

# Inject corporate CA certificates into Dockerfiles for builds behind TLS-intercepting proxies.
# Creates a temp Dockerfile that appends the cert to the system trust store after each FROM stage.
# Uses --build-context so the cert is available without copying it into the source repo.
prepare_dockerfile() {
    local original="$1"
    local output="$2"

    if [ -f "${CERT_DIR}/AMD_COMBINED.crt" ]; then
        sed '/^FROM /{
            a COPY --from=certs AMD_COMBINED.crt /tmp/AMD_COMBINED.crt
            a RUN cat /tmp/AMD_COMBINED.crt >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
        }' "${original}" > "${output}"
    else
        cp "${original}" "${output}"
    fi
}

build_image() {
    local spec="$1"
    IFS='|' read -r name tag dockerfile context _ k8s_deploys <<< "${spec}"

    echo "================================================"
    echo "  ${name}"
    echo "  Tag:        ${tag}"
    echo "  Dockerfile: ${dockerfile}"
    echo "  Context:    ${context}"
    echo "================================================"

    if [ ! -f "${dockerfile}" ]; then
        echo "  SKIP: Dockerfile not found at ${dockerfile}"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${name}")
        return 1
    fi

    if [ ! -d "${context}" ]; then
        echo "  SKIP: Build context not found at ${context}"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${name}")
        return 1
    fi

    local log_file="${LOG_DIR}/${name}.log"
    local start_time=$(date +%s)
    local build_dockerfile="${LOG_DIR}/${name}.Dockerfile"

    prepare_dockerfile "${dockerfile}" "${build_dockerfile}"

    local extra_args=""
    if [ -f "${CERT_DIR}/AMD_COMBINED.crt" ]; then
        extra_args="--build-context certs=${CERT_DIR}"
        echo "  (injecting AMD CA certificates)"
    fi

    echo "  Building... (log: ${log_file})"
    if docker build \
        ${DOCKER_NO_CACHE} \
        ${extra_args} \
        -f "${build_dockerfile}" \
        -t "${tag}" \
        "${context}" > "${log_file}" 2>&1; then
        local elapsed=$(( $(date +%s) - start_time ))
        echo "  Built in ${elapsed}s"
    else
        local elapsed=$(( $(date +%s) - start_time ))
        echo "  FAILED after ${elapsed}s"
        echo ""
        echo "  --- Last 30 lines of build log ---"
        tail -30 "${log_file}" | sed 's/^/  | /'
        echo "  --- End of log (full log: ${log_file}) ---"
        echo ""
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("${name}")
        return 1
    fi

    if [ "${LOAD_INTO_KIND}" = "1" ]; then
        echo "  Loading into Kind cluster '${CLUSTER_NAME}'..."
        if kind load docker-image "${tag}" --name "${CLUSTER_NAME}" >> "${log_file}" 2>&1; then
            echo "  Loaded into Kind"
        else
            echo "  FAILED to load into Kind"
            echo ""
            echo "  --- Last 10 lines ---"
            tail -10 "${log_file}" | sed 's/^/  | /'
            echo ""
            FAILED=$((FAILED + 1))
            FAILED_NAMES+=("${name}")
            return 1
        fi
    fi

    BUILT=$((BUILT + 1))
    if [ -n "${k8s_deploys}" ]; then
        IFS=',' read -ra deploys <<< "${k8s_deploys}"
        DEPLOYMENTS_TO_RESTART+=("${deploys[@]}")
    fi
    echo "  Done"
    echo ""
}

for spec in ${IMAGES_TO_BUILD}; do
    build_image "${spec}" || true
done

# ─── Restart deployments to pick up new images ──────────────────────────────

if [ ${#DEPLOYMENTS_TO_RESTART[@]} -gt 0 ] && [ "${LOAD_INTO_KIND}" = "1" ]; then
    # Deduplicate
    UNIQUE_DEPLOYS=($(printf '%s\n' "${DEPLOYMENTS_TO_RESTART[@]}" | sort -u))
    echo "================================================"
    echo "  Restarting ${#UNIQUE_DEPLOYS[@]} deployment(s)..."
    echo "================================================"
    for deploy_spec in "${UNIQUE_DEPLOYS[@]}"; do
        IFS='/' read -r ns deploy_name <<< "${deploy_spec}"
        if kubectl get deploy "${deploy_name}" -n "${ns}" &>/dev/null; then
            kubectl rollout restart deploy/"${deploy_name}" -n "${ns}" 2>&1
            echo "  ✓ ${ns}/${deploy_name} restarted"
        else
            echo "  - ${ns}/${deploy_name} not found (skipped)"
        fi
    done
    echo ""
fi

echo "================================================"
echo "  Results: ${BUILT} built, ${FAILED} failed"
echo "================================================"

if [ ${FAILED} -gt 0 ]; then
    echo ""
    echo "Failed images: ${FAILED_NAMES[*]}"
    echo ""
    echo "To retry failed images:"
    echo "  $0 ${FAILED_NAMES[*]}"
    echo ""
    echo "To retry without cache:"
    echo "  $0 --no-cache ${FAILED_NAMES[*]}"
    echo ""
    echo "Build logs are in: ${LOG_DIR}"
    echo "  (they will be cleaned up when this script exits)"
    echo ""
    echo "Tip: To keep logs, copy them before exiting:"
    echo "  cp ${LOG_DIR}/*.log /tmp/"
    exit 1
fi
