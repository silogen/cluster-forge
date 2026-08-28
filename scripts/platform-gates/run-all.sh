#!/usr/bin/env bash
# Run platform gates and write a mandatory report artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PATH="${PLATFORM_GATES_REPORT:-${HOME}/platform-gates-report.txt}"
BLOOM_LOG="${PLATFORM_GATES_BLOOM_LOG:-${HOME}/bloom-cli.log}"
BLOOM_LOG_TAIL_LINES="${PLATFORM_GATES_BLOOM_LOG_TAIL:-50}"

GATES=(
  gateway-programmed
  ai-gateway-webhook
  https-aiwb-ui
)

usage() {
  sed -n '2,20p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      REPORT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${PLATFORM_DOMAIN:-}" ]]; then
  echo "PLATFORM_DOMAIN is required (cluster apex domain)" >&2
  exit 2
fi

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
overall="PASS"
declare -a gate_names=()
declare -a gate_statuses=()
declare -a gate_details=()

write_report() {
  {
    echo "=== Platform gates report ==="
    echo "Host: ${PLATFORM_GATES_HOST:-$(hostname -f 2>/dev/null || hostname)}"
    echo "ClusterForge release: ${CLUSTERFORGE_RELEASE:-unknown}"
    echo "Domain: ${PLATFORM_DOMAIN}"
    echo "Started: ${started_at}"
    echo ""
    local index
    for index in "${!gate_names[@]}"; do
      echo "[${gate_names[$index]}] ${gate_statuses[$index]}"
      echo "${gate_details[$index]}" | sed 's/^/  /'
      echo ""
    done
    if [[ "${overall}" != "PASS" && -f "${BLOOM_LOG}" ]]; then
      echo "[bloom-log-tail] last ${BLOOM_LOG_TAIL_LINES} lines of ${BLOOM_LOG}"
      tail -n "${BLOOM_LOG_TAIL_LINES}" "${BLOOM_LOG}" | sed 's/^/  /'
      echo ""
    fi
    echo "Finished: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Overall: ${overall}"
  } > "${REPORT_PATH}"
}

run_gate() {
  local gate="$1"
  local output
  local status=0
  set +e
  output="$("${SCRIPT_DIR}/${gate}.sh" 2>&1)"
  status=$?
  set -e
  gate_names+=("${gate}")
  if [[ "${status}" -eq 0 ]]; then
    gate_statuses+=("PASS")
  else
    gate_statuses+=("FAIL")
    overall="FAIL"
  fi
  gate_details+=("${output}")
  return "${status}"
}

for gate in "${GATES[@]}"; do
  run_gate "${gate}" || true
done

write_report
cat "${REPORT_PATH}"

if [[ "${overall}" == "PASS" ]]; then
  exit 0
fi
exit 1
