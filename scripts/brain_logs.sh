#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

echo "install_root=${BRAIN_INSTALL_ROOT}"

mkdir -p "${BRAIN_LOG_DIR}"
last_log="${BRAIN_LOG_DIR}/lms.log"
for candidate in \
  "${BRAIN_LOG_DIR}/lms.log" \
  "${BRAIN_LOG_DIR}/llama-server.log" \
  "${BRAIN_OPEN_WEBUI_DATA_DIR}/logs/open-webui.log" \
  "${BRAIN_INSTALL_ROOT}/mcp/logs/mcp-proxy.log"; do
  if [[ -f "${candidate}" ]]; then
    last_log="${candidate}"
    break
  fi
done
mkdir -p "$(dirname "${last_log}")"
touch "${last_log}"
echo "logs_dir=${BRAIN_LOG_DIR}"
echo "last_log=${last_log}"

for log_file in \
  "${BRAIN_LOG_DIR}/lms.log" \
  "${BRAIN_LOG_DIR}/llama-server.log" \
  "${BRAIN_OPEN_WEBUI_DATA_DIR}/logs/open-webui.log" \
  "${BRAIN_INSTALL_ROOT}/mcp/logs/mcp-proxy.log"; do
  if [[ -f "${log_file}" ]]; then
    echo
    echo "==> ${log_file}"
    tail -n "${BRAIN_LOG_LINES:-120}" "${log_file}"
  fi
done
