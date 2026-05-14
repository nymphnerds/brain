#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

installed=false
runtime_present=false
data_present=false
llm_running=false
open_webui_running=false
mcp_running=false
mcpo_running=false
model_configured=false
local_model="none"
remote_model="deepseek/deepseek-chat"
openrouter_key="not_set"
version=not-installed
health=unavailable
state=available
marker="${BRAIN_INSTALL_ROOT}/.nymph-module-version"
detail="Not installed."

if [[ -f "${marker}" ]]; then
  installed=true
  runtime_present=true
  version="$(head -n 1 "${marker}" 2>/dev/null || true)"
  [[ -n "${version}" ]] || version=unknown
  detail="Brain installed."
fi

if [[ -d "${BRAIN_INSTALL_ROOT}/models" || -d "${BRAIN_OPEN_WEBUI_DATA_DIR}" || -d "${BRAIN_INSTALL_ROOT}/mcp" || -d "${BRAIN_INSTALL_ROOT}/secrets" ]] ||
   [[ -d "${BRAIN_LOG_DIR}" && -n "$(find "${BRAIN_LOG_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  data_present=true
fi

if [[ "${installed}" == "true" ]] && brain_model_configured; then
  model_configured=true
fi

if [[ -f "${BRAIN_BIN_DIR}/lms-start" ]]; then
  configured_model="$(sed -n 's/^MODEL_KEY="\([^"]*\)".*/\1/p' "${BRAIN_BIN_DIR}/lms-start" | head -n 1)"
  if [[ -n "${configured_model}" ]]; then
    local_model="${configured_model}"
  fi
fi

if [[ -f "${BRAIN_INSTALL_ROOT}/secrets/llm-wrapper.env" ]]; then
  configured_remote="$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${BRAIN_INSTALL_ROOT}/secrets/llm-wrapper.env" | tail -1)"
  configured_key="$(sed -n 's/^OPENROUTER_API_KEY=//p' "${BRAIN_INSTALL_ROOT}/secrets/llm-wrapper.env" | tail -1)"
  [[ -n "${configured_remote}" ]] && remote_model="${configured_remote}"
  [[ -n "${configured_key}" ]] && openrouter_key="saved"
fi

if [[ "${installed}" == "true" ]] && brain_probe_url "http://${BRAIN_LLM_HOST}:${BRAIN_LLM_PORT}/v1/models" >/dev/null 2>&1; then
  llm_running=true
fi

if [[ "${installed}" == "true" ]] && brain_probe_url "http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}" >/dev/null 2>&1; then
  open_webui_running=true
fi

if [[ "${installed}" == "true" ]]; then
  if brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}/status" >/dev/null 2>&1 ||
     brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}/" >/dev/null 2>&1; then
    mcp_running=true
  fi
fi

if [[ "${installed}" == "true" ]] && brain_probe_url "http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}/filesystem/openapi.json" >/dev/null 2>&1; then
  mcpo_running=true
fi

if [[ "${llm_running}" == "true" || "${open_webui_running}" == "true" || "${mcp_running}" == "true" || "${mcpo_running}" == "true" ]]; then
  state=running
  health=ok
elif [[ "${installed}" == "true" && "${model_configured}" == "false" ]]; then
  state=needs_attention
  health=degraded
  detail="Brain is installed, but no local model is configured."
elif [[ "${installed}" == "true" ]]; then
  state=installed
  health=ok
elif [[ "${data_present}" == "true" ]]; then
  detail="Brain preserved data remains, but runtime files are not installed."
fi

if [[ "${installed}" == "true" ]]; then
  detail="LLM: ${llm_running}; MCP: ${mcp_running}; WebUI: ${open_webui_running}; Local model: ${local_model}; Remote model: ${remote_model}; OpenRouter key: ${openrouter_key}."
fi

cat <<EOF
id=brain
name=Brain
installed=${installed}
runtime_present=${runtime_present}
data_present=${data_present}
version=${version}
running=$([[ "${state}" == "running" ]] && echo true || echo false)
state=${state}
health=${health}
model_configured=${model_configured}
local_model=${local_model}
remote_model=${remote_model}
openrouter_key=${openrouter_key}
llm_running=${llm_running}
open_webui_running=${open_webui_running}
mcp_running=${mcp_running}
mcpo_running=${mcpo_running}
llm_url=http://${BRAIN_LLM_HOST}:${BRAIN_LLM_PORT}/v1/chat/completions
open_webui_url=http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}
mcp_url=http://${BRAIN_MCP_HOST}:${BRAIN_MCP_PORT}
mcpo_url=http://${BRAIN_MCP_HOST}:${BRAIN_MCPO_OPENAPI_PORT}
install_root=${BRAIN_INSTALL_ROOT}
logs_dir=${BRAIN_LOG_DIR}
marker=${marker}
detail=${detail}
EOF
