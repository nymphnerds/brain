#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

if [[ ! -x "${BRAIN_BIN_DIR}/open-webui-start" ]]; then
  echo "Brain is not installed. Run scripts/install_brain.sh first." >&2
  exit 1
fi

"${BRAIN_BIN_DIR}/open-webui-start"
echo "http://${BRAIN_OPEN_WEBUI_HOST}:${BRAIN_OPEN_WEBUI_PORT}"
