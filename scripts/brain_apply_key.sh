#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_brain_common.sh"

OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
if [[ -z "${OPENROUTER_API_KEY}" ]]; then
  echo "OpenRouter API key is missing." >&2
  exit 2
fi

SECRET_DIR="${BRAIN_INSTALL_ROOT}/secrets"
SECRET_FILE="${SECRET_DIR}/llm-wrapper.env"
remote_model="deepseek/deepseek-chat"

if [[ -f "${SECRET_FILE}" ]]; then
  existing_remote="$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${SECRET_FILE}" | tail -1)"
  if [[ -n "${existing_remote}" ]]; then
    remote_model="${existing_remote}"
  fi
fi

mkdir -p "${SECRET_DIR}"
{
  printf '%s\n' "# Nymphs-Brain llm-wrapper configuration"
  printf 'OPENROUTER_API_KEY=%s\n' "${OPENROUTER_API_KEY}"
  printf 'REMOTE_LLM_MODEL=%s\n' "${remote_model}"
} > "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"

echo "OpenRouter key updated for Nymphs-Brain llm-wrapper."
