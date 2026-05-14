#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

MODEL_MANAGER="${BRAIN_BIN_DIR}/lms-model"
if [[ ! -x "${MODEL_MANAGER}" ]]; then
  echo "Brain model manager is missing: ${MODEL_MANAGER}" >&2
  echo "Repair or update the Brain module, then try Manage Models again." >&2
  exit 1
fi

exec "${MODEL_MANAGER}" "$@"
