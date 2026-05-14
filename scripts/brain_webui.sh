#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

if [[ ! -x "${BRAIN_BIN_DIR}/open-webui-start" ]]; then
  echo "Brain is not installed. Run scripts/install_brain.sh first." >&2
  exit 1
fi

app_url="http://localhost:${BRAIN_OPEN_WEBUI_PORT}"
health_url="http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}"
log_file="${BRAIN_OPEN_WEBUI_DATA_DIR}/logs/open-webui-manager-start.log"

mkdir -p "$(dirname "${log_file}")"

if brain_probe_url "${health_url}" >/dev/null 2>&1; then
  echo "Open WebUI is already running."
  echo "App: ${app_url}"
  exit 0
fi

echo "Starting Open WebUI..."
nohup "${BRAIN_BIN_DIR}/open-webui-start" > "${log_file}" 2>&1 &
starter_pid="$!"

sleep 1
if ! kill -0 "${starter_pid}" >/dev/null 2>&1; then
  wait "${starter_pid}"
fi

echo "App: ${app_url}"
echo "Logs: ${log_file}"
