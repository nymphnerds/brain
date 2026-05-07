#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

echo "install_root=${BRAIN_INSTALL_ROOT}"

for log_file in \
  "${BRAIN_LOG_DIR}/llama-server.log" \
  "${BRAIN_OPEN_WEBUI_DATA_DIR}/logs/open-webui.log" \
  "${BRAIN_INSTALL_ROOT}/mcp/logs/mcp-proxy.log"; do
  if [[ -f "${log_file}" ]]; then
    echo
    echo "==> ${log_file}"
    tail -n "${BRAIN_LOG_LINES:-120}" "${log_file}"
  fi
done
