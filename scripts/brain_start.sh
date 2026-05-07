#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

if [[ ! -x "${BRAIN_BIN_DIR}/open-webui-start" ]]; then
  echo "Brain is not installed. Run scripts/install_brain.sh first." >&2
  exit 1
fi

if brain_model_configured && [[ -x "${BRAIN_BIN_DIR}/lms-start" ]]; then
  "${BRAIN_BIN_DIR}/lms-start" || true
else
  echo "No local Brain model configured yet; skipping llama-server start."
fi

"${BRAIN_BIN_DIR}/open-webui-start"
