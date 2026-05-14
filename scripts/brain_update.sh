#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${HOME}/Nymphs-Brain"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "${SCRIPT_SOURCE_DIR}/.." && pwd)"
SCRIPTS_DIR="${INSTALL_ROOT}/scripts"

mkdir -p "${INSTALL_ROOT}" "${SCRIPTS_DIR}"

install -m 644 "${MODULE_ROOT}/nymph.json" "${INSTALL_ROOT}/nymph.json"
install -m 755 "${MODULE_ROOT}/scripts/_brain_common.sh" "${SCRIPTS_DIR}/_brain_common.sh"
for manager_script in "${MODULE_ROOT}"/scripts/brain_*.sh; do
  [[ -f "${manager_script}" ]] || continue
  install -m 755 "${manager_script}" "${SCRIPTS_DIR}/$(basename "${manager_script}")"
done

module_version="$(python3 - "${MODULE_ROOT}/nymph.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

print(str(manifest.get("version", "unknown")).strip() or "unknown")
PY
)"

printf '%s\n' "${module_version}" > "${INSTALL_ROOT}/.nymph-module-version"

echo "Brain module wrappers updated."
echo "installed_version=${module_version}"
