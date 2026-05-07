#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

[[ -x "${BRAIN_BIN_DIR}/open-webui-stop" ]] && "${BRAIN_BIN_DIR}/open-webui-stop" || true
[[ -x "${BRAIN_BIN_DIR}/mcp-stop" ]] && "${BRAIN_BIN_DIR}/mcp-stop" || true
[[ -x "${BRAIN_BIN_DIR}/lms-stop" ]] && "${BRAIN_BIN_DIR}/lms-stop" || true

echo "Brain services stopped."
