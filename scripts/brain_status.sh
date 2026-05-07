#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

installed=false
llm_running=false
open_webui_running=false
mcp_running=false
mcpo_running=false
model_configured=false
detail="Not installed."

if [[ -x "${BRAIN_BIN_DIR}/brain-status" ]]; then
  installed=true
  detail="Brain installed."
fi

if brain_model_configured; then
  model_configured=true
fi

if brain_probe_url "http://${BRAIN_LLM_HOST}:${BRAIN_LLM_PORT}/v1/models" >/dev/null 2>&1; then
  llm_running=true
fi

if brain_probe_url "http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}" >/dev/null 2>&1; then
  open_webui_running=true
fi

if brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}/status" >/dev/null 2>&1 ||
   brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}/" >/dev/null 2>&1; then
  mcp_running=true
fi

if brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/filesystem/openapi.json" >/dev/null 2>&1; then
  mcpo_running=true
fi

cat <<EOF
id=brain
name=Brain
installed=${installed}
model_configured=${model_configured}
llm_running=${llm_running}
open_webui_running=${open_webui_running}
mcp_running=${mcp_running}
mcpo_running=${mcpo_running}
llm_url=http://${BRAIN_LLM_HOST}:${BRAIN_LLM_PORT}/v1/chat/completions
open_webui_url=http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}
mcp_url=http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}
mcpo_url=http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}
install_root=${BRAIN_INSTALL_ROOT}
detail=${detail}
EOF
