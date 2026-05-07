#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

PURGE=0
DRY_RUN=0
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: brain_uninstall.sh [--dry-run] [--yes] [--purge]

Default uninstall removes Brain runtime/program files but preserves models,
Open WebUI data, MCP config/data, secrets, and logs.
--purge removes the whole install root, including models and secrets.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

echo "Brain uninstall plan"
echo "install_root=${BRAIN_INSTALL_ROOT}"
if [[ "${PURGE}" -eq 1 ]]; then
  echo "mode=purge"
  echo "delete=${BRAIN_INSTALL_ROOT}"
else
  echo "mode=uninstall"
  echo "delete=${BRAIN_INSTALL_ROOT}/bin"
  echo "delete=${BRAIN_INSTALL_ROOT}/venv"
  echo "delete=${BRAIN_INSTALL_ROOT}/mcp-venv"
  echo "delete=${BRAIN_INSTALL_ROOT}/open-webui-venv"
  echo "delete=${BRAIN_INSTALL_ROOT}/local-tools"
  echo "delete=${BRAIN_INSTALL_ROOT}/npm-global"
  echo "delete=${BRAIN_INSTALL_ROOT}/lmstudio"
  echo "delete=${BRAIN_INSTALL_ROOT}/nymph-agent.py"
  echo "preserve=${BRAIN_INSTALL_ROOT}/models"
  echo "preserve=${BRAIN_INSTALL_ROOT}/open-webui-data"
  echo "preserve=${BRAIN_INSTALL_ROOT}/mcp"
  echo "preserve=${BRAIN_INSTALL_ROOT}/secrets"
  echo "preserve=${BRAIN_INSTALL_ROOT}/logs"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  exit 0
fi

if [[ "${YES}" -ne 1 ]]; then
  echo "Refusing to delete without --yes. Run with --dry-run first to preview." >&2
  exit 2
fi

"${SCRIPT_DIR}/brain_stop.sh" || true

if [[ ! -d "${BRAIN_INSTALL_ROOT}" ]]; then
  echo "Brain is already uninstalled."
  exit 0
fi

if [[ "${PURGE}" -eq 1 ]]; then
  rm -rf "${BRAIN_INSTALL_ROOT}"
else
  rm -rf \
    "${BRAIN_INSTALL_ROOT}/bin" \
    "${BRAIN_INSTALL_ROOT}/venv" \
    "${BRAIN_INSTALL_ROOT}/mcp-venv" \
    "${BRAIN_INSTALL_ROOT}/open-webui-venv" \
    "${BRAIN_INSTALL_ROOT}/local-tools" \
    "${BRAIN_INSTALL_ROOT}/npm-global" \
    "${BRAIN_INSTALL_ROOT}/lmstudio" \
    "${BRAIN_INSTALL_ROOT}/nymph-agent.py" \
    "${BRAIN_INSTALL_ROOT}/install-summary.txt"
fi

echo "Brain uninstalled."
