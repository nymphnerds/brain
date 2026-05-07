#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BRAIN_INSTALL_ROOT="${BRAIN_INSTALL_ROOT:-${NYMPHS_BRAIN_INSTALL_ROOT:-$HOME/Nymphs-Brain}}"
BRAIN_BIN_DIR="${BRAIN_INSTALL_ROOT}/bin"
BRAIN_LOG_DIR="${BRAIN_INSTALL_ROOT}/logs"
BRAIN_OPEN_WEBUI_DATA_DIR="${BRAIN_INSTALL_ROOT}/open-webui-data"

BRAIN_LLM_HOST="${NYMPHS_BRAIN_LLM_HOST:-127.0.0.1}"
BRAIN_LLM_PORT="${NYMPHS_BRAIN_LLM_PORT:-8000}"
BRAIN_OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-127.0.0.1}"
BRAIN_OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-8081}"
BRAIN_MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-127.0.0.1}}"
BRAIN_MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-8100}}"
BRAIN_MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-8099}"

brain_probe_url() {
  local url="${1}"
  python3 - "${url}" <<'PY'
import sys
from urllib.request import urlopen

try:
    with urlopen(sys.argv[1], timeout=2) as response:
        print(response.read().decode("utf-8", errors="replace"))
except Exception as exc:
    raise SystemExit(str(exc))
PY
}

brain_model_configured() {
  local start_script="${BRAIN_BIN_DIR}/lms-start"
  [[ -f "${start_script}" ]] || return 1
  local model_key
  model_key="$(sed -n 's/^MODEL_KEY="\([^"]*\)".*/\1/p' "${start_script}" | head -n 1)"
  [[ -n "${model_key}" && "${model_key}" != "none" ]]
}
