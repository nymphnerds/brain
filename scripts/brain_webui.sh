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

for _ in $(seq 1 90); do
  if brain_probe_url "${health_url}" >/dev/null 2>&1; then
    echo "Open WebUI is ready."
    echo "App: ${app_url}"
    echo "Logs: ${log_file}"
    exit 0
  fi

  if ! kill -0 "${starter_pid}" >/dev/null 2>&1; then
    wait "${starter_pid}"
  fi

  echo "Open WebUI is still starting..."
  sleep 1
done

echo "Open WebUI did not become ready in time."
echo "App: ${app_url}"
echo "Logs: ${log_file}"
echo "OpenAPI tool routes:"
echo "- filesystem: http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/filesystem/docs"
echo "- memory: http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/memory/docs"
echo "- web-forager: http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/web-forager/docs"
echo "- context7: http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/context7/docs"
echo "MCP config: ${BRAIN_INSTALL_ROOT}/mcp/config/mcp-proxy-servers.json"
echo "mcpo config: ${BRAIN_INSTALL_ROOT}/mcp/config/mcpo-servers.json"
echo "Cline config template: ${BRAIN_INSTALL_ROOT}/mcp/config/cline-mcp-settings.json"
echo "Open WebUI setup note: ${BRAIN_INSTALL_ROOT}/mcp/config/open-webui-mcp-servers.md"
exit 1
