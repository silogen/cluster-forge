#!/usr/bin/env bash
# Platform gate: mutating webhook accepts probe pods (no heal).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../ai-gateway-webhook-health.sh" --probe-only
