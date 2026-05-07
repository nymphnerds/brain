#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

if [[ -x "${BRAIN_BIN_DIR}/brain-refresh" ]]; then
  "${BRAIN_BIN_DIR}/brain-refresh"
else
  "${SCRIPT_DIR}/install_brain.sh" --install-root "${BRAIN_INSTALL_ROOT}"
fi
