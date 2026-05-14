#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

MODELS_DIR="${BRAIN_INSTALL_ROOT}/models"
mkdir -p "${MODELS_DIR}"

echo "directory=${MODELS_DIR}"
