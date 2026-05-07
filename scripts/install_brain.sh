#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="${HOME}/Nymphs-Brain"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ID=""
QUANTIZATION="q4_k_m"
CONTEXT_LENGTH="16384"
CONTEXT_SET="0"
DOWNLOAD_MODEL="0"
QUIET="0"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"

usage() {
  cat <<'EOF'
Usage: install_nymphs_brain.sh [options]

Experimental optional local LLM stack for NymphsCore.

Options:
  --install-root PATH     Install root. Default: $HOME/Nymphs-Brain
  --model MODEL_ID        Optional local model id. Default: none; pick one after install.
  --quant QUANT           Quantization suffix. Default: q4_k_m
  --context N             Context length. Default: 16384
  --download-model        Download the specified --model now
  --openrouter-api-key K  Optional key for the Brain llm-wrapper tool bridge
  --quiet                 Reduce chatter where possible
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root)
      INSTALL_ROOT="${2:?Missing value for --install-root}"
      shift 2
      ;;
    --model)
      MODEL_ID="${2:?Missing value for --model}"
      shift 2
      ;;
    --quant)
      QUANTIZATION="${2:?Missing value for --quant}"
      shift 2
      ;;
    --context)
      CONTEXT_LENGTH="${2:?Missing value for --context}"
      CONTEXT_SET="1"
      shift 2
      ;;
    --download-model)
      DOWNLOAD_MODEL="1"
      shift
      ;;
    --openrouter-api-key)
      OPENROUTER_API_KEY="${2:?Missing value for --openrouter-api-key}"
      shift 2
      ;;
    --quiet)
      QUIET="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "${CONTEXT_LENGTH}" =~ ^[0-9]+$ ]] || [[ "${CONTEXT_LENGTH}" -lt 1024 ]]; then
  echo "Context length must be a number >= 1024." >&2
  exit 2
fi

BIN_DIR="${INSTALL_ROOT}/bin"
VENV_DIR="${INSTALL_ROOT}/venv"
NPM_GLOBAL="${INSTALL_ROOT}/npm-global"
LOCAL_TOOLS_DIR="${INSTALL_ROOT}/local-tools"
LOCAL_BIN_DIR="${LOCAL_TOOLS_DIR}/bin"
LOCAL_NODE_DIR="${LOCAL_TOOLS_DIR}/node"
SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
MCP_VENV_DIR="${INSTALL_ROOT}/mcp-venv"
MODELS_DIR="${INSTALL_ROOT}/models"
LMSTUDIO_DIR="${INSTALL_ROOT}/lmstudio"
MCP_DIR="${INSTALL_ROOT}/mcp"
MCP_CONFIG_DIR="${MCP_DIR}/config"
MCP_DATA_DIR="${MCP_DIR}/data"
MCP_LOG_DIR="${MCP_DIR}/logs"
OPEN_WEBUI_VENV_DIR="${INSTALL_ROOT}/open-webui-venv"
OPEN_WEBUI_DATA_DIR="${INSTALL_ROOT}/open-webui-data"
OPEN_WEBUI_LOG_DIR="${OPEN_WEBUI_DATA_DIR}/logs"
SECRET_DIR="${INSTALL_ROOT}/secrets"
OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-127.0.0.1}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-8081}"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-127.0.0.1}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-8100}}"
MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-8099}"
LLM_API_BASE_URL="${NYMPHS_BRAIN_LLM_API_BASE_URL:-http://127.0.0.1:8000/v1}"

export PATH="${BIN_DIR}:${LOCAL_BIN_DIR}:${LOCAL_NODE_DIR}/bin:${NPM_GLOBAL}/bin:${PATH}"

log() {
  if [[ "${QUIET}" != "1" ]]; then
    echo "$@"
  fi
}

python_has_venv() {
  local python_bin="$1"
  "${python_bin}" - <<'PYEOF' >/dev/null 2>&1
import venv
PYEOF
}

select_python_bin() {
  local candidate
  for candidate in python3.11 python3.10 python3; do
    if command -v "${candidate}" >/dev/null 2>&1 && python_has_venv "${candidate}"; then
      command -v "${candidate}"
      return 0
    fi
  done

  return 1
}

add_lmstudio_paths() {
  local candidates=(
    "${LOCAL_NODE_DIR}/bin"
    "${LOCAL_BIN_DIR}"
    "${HOME}/.lmstudio/bin"
    "${HOME}/.cache/lm-studio/bin"
    "${HOME}/.local/bin"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "${candidate}" ]]; then
      export PATH="${candidate}:${PATH}"
    fi
  done
}

detect_node_arch() {
  case "$(uname -m)" in
    x86_64) echo "linux-x64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *)
      echo "Unsupported architecture for local Node bootstrap: $(uname -m)" >&2
      return 1
      ;;
  esac
}

ensure_local_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi

  local node_arch
  local node_version="20.19.0"
  local node_archive=""
  local node_url=""
  local temp_extract_dir=""
  local tarball=""

  node_arch="$(detect_node_arch)"
  node_archive="node-v${node_version}-${node_arch}"
  node_url="https://nodejs.org/dist/v${node_version}/${node_archive}.tar.xz"
  temp_extract_dir="$(mktemp -d)"
  tarball="${temp_extract_dir}/${node_archive}.tar.xz"

  echo "Installing local Node.js runtime (${node_version}, ${node_arch})..."
  curl -fsSL "${node_url}" -o "${tarball}"
  rm -rf "${LOCAL_NODE_DIR}"
  mkdir -p "${LOCAL_TOOLS_DIR}"
  tar -xf "${tarball}" -C "${temp_extract_dir}"
  mv "${temp_extract_dir}/${node_archive}" "${LOCAL_NODE_DIR}"
  rm -rf "${temp_extract_dir}"
  export PATH="${LOCAL_NODE_DIR}/bin:${PATH}"
}

detect_installation_type() {
  local lms_start="${INSTALL_ROOT}/bin/lms-start"
  
  if [[ ! -f "$lms_start" ]]; then
    echo "new"
    return
  fi
  
  # Check if it's using LM Studio server (port 1234 or "lms serve")
  if grep -qE "(localhost:1234|127\.0\.0\.1:1234|lms\s+server\s+(start|stop))" "$lms_start"; then
    echo "lmstudio-migrate"
  elif grep -q "llama-server.*--port 8000" "$lms_start"; then
    echo "existing-llama"
  elif grep -q "curl.*127\.0\.0\.1:8000" "$lms_start"; then
    echo "existing-llama"
  else
    echo "unknown"
  fi
}

migrate_from_lmstudio() {
  echo ""
  echo "============================================================"
  echo "DETECTED EXISTING LM STUDIO INSTALLATION (port 1234)"
  echo "============================================================"
  echo ""
  echo "Migrating to llama-server hybrid architecture..."
  echo ""
  
  # Stop any running LM Studio server first
  if [[ -f "${INSTALL_ROOT}/logs/lms.pid" ]]; then
    local old_pid
    old_pid=$(cat "${INSTALL_ROOT}/logs/lms.pid" 2>/dev/null || true)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
      echo "Stopping existing LM Studio server (PID ${old_pid})..."
      kill "$old_pid" >/dev/null 2>&1 || true
      sleep 2
    fi
  fi
  
  # Also try pkill for LM Studio processes
  pkill -f "lms.*server" 2>/dev/null || true
  
  # Backup old scripts
  local backup_dir="${INSTALL_ROOT}/bin/backup-lmstudio-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_dir}" 2>/dev/null || true
  
  for script in lms-start lms-stop brain-status open-webui-start nymph-agent.py; do
    if [[ -f "${BIN_DIR}/${script}" ]]; then
      cp "${BIN_DIR}/${script}" "${backup_dir}/" 2>/dev/null || true
    fi
  done
  
  if [[ -d "${backup_dir}" ]] && [[ "$(ls -A "${backup_dir}" 2>/dev/null)" ]]; then
    echo "Backed up old LM Studio scripts to: ${backup_dir}"
  fi
  
  # Update nymph-agent.py if it exists and references port 1234
  local agent_path="${INSTALL_ROOT}/nymph-agent.py"
  if [[ -f "$agent_path" ]]; then
    if grep -q "127.0.0.1:1234\|localhost:1234" "$agent_path"; then
      echo "Updating nymph-agent.py to use llama-server (port 8000)..."
      sed -i 's|http://127\.0\.0\.1:1234|http://127.0.0.1:8000|g' "$agent_path"
      sed -i 's|http://localhost:1234|http://localhost:8000|g' "$agent_path"
    fi
  fi
  
  echo ""
  echo "Migration preparation complete. Installing llama-server scripts..."
  echo ""
}

detect_vram_mb() {
  # Check if Manager passed the actual GPU VRAM from Windows
  local vram_env="${NYMPHS3D_GPU_VRAM_MB:-0}"
  if [[ -n "${vram_env}" && "${vram_env}" =~ ^[0-9]+$ ]]; then
    echo "${vram_env}"
    return
  fi

  # Fall back to local nvidia-smi detection (may be limited by WSL memory config)
  local smi_cmd=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    smi_cmd="nvidia-smi"
  elif command -v nvidia-smi.exe >/dev/null 2>&1; then
    smi_cmd="nvidia-smi.exe"
  elif [[ -x "/mnt/c/Windows/System32/nvidia-smi.exe" ]]; then
    smi_cmd="/mnt/c/Windows/System32/nvidia-smi.exe"
  fi

  if [[ -z "${smi_cmd}" ]]; then
    echo 0
    return
  fi

  "${smi_cmd}" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null |
    head -n 1 |
    tr -d '\r ' |
    awk '{print int($1)}'
}

preserve_existing_model_config() {
  local lms_start="${INSTALL_ROOT}/bin/lms-start"
  local existing_model=""
  local existing_context=""

  if [[ ! -f "${lms_start}" ]]; then
    return 0
  fi

  existing_model="$(sed -n 's/^MODEL_KEY="\([^"]*\)".*/\1/p' "${lms_start}" | head -n 1)"
  existing_context="$(sed -n 's/^CONTEXT_LENGTH="\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' "${lms_start}" | head -n 1)"

  if [[ -n "${existing_model}" ]]; then
    MODEL_ID="${existing_model}"
    echo "Preserving configured local model: ${MODEL_ID}"
  fi

  if [[ "${CONTEXT_SET}" != "1" && -n "${existing_context}" ]]; then
    CONTEXT_LENGTH="${existing_context}"
    echo "Preserving configured context length: ${CONTEXT_LENGTH}"
  fi
}

ensure_secret_file() {
  local path="$1"
  local bytes="$2"

  if [[ -s "${path}" ]]; then
    chmod 600 "${path}" || true
    return 0
  fi

  "${PYTHON_BIN}" - "${path}" "${bytes}" <<'PYEOF'
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
bytes_len = int(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(secrets.token_urlsafe(bytes_len) + "\n", encoding="utf-8")
PYEOF
  chmod 600 "${path}" || true
}

ensure_python_venv() {
  local venv_dir="$1"
  local label="$2"

  if [[ ! -x "${venv_dir}/bin/python3" ]] || [[ ! -x "${venv_dir}/bin/pip" ]]; then
    if [[ -d "${venv_dir}" ]]; then
      echo "Removing incomplete ${label} venv at ${venv_dir}"
      rm -rf "${venv_dir}"
    fi
    echo "Creating ${label} venv at ${venv_dir}"
    "${PYTHON_BIN}" -m venv "${venv_dir}"
  fi
}

echo "Nymphs-Brain experimental installer"
echo "Install root: ${INSTALL_ROOT}"

# Create directories including new models and lmstudio directories
mkdir -p \
  "${BIN_DIR}" \
  "${VENV_DIR}" \
  "${NPM_GLOBAL}" \
  "${LOCAL_TOOLS_DIR}" \
  "${LOCAL_BIN_DIR}" \
  "${SCRIPTS_DIR}" \
  "${MODELS_DIR}" \
  "${LMSTUDIO_DIR}" \
  "${MCP_CONFIG_DIR}" \
  "${MCP_DATA_DIR}" \
  "${MCP_LOG_DIR}" \
  "${OPEN_WEBUI_DATA_DIR}" \
  "${OPEN_WEBUI_LOG_DIR}" \
  "${SECRET_DIR}"

# Migrate existing models from old locations to new centralized models directory
# Note: We do NOT remove .lmstudio here as it will be a symlink created later
migrate_existing_models() {
  local source_paths=(
    "${HOME}/.cache/lm-studio/models"
  )
  
  for src in "${source_paths[@]}"; do
    if [[ -d "$src" ]] && [[ "$(ls -A "$src" 2>/dev/null)" ]]; then
      echo "Migrating existing models from ${src} to ${MODELS_DIR}..."
      cp -r "$src/"* "${MODELS_DIR}/" 2>/dev/null || true
    fi
  done
  
  # Only remove .cache/lm-studio if it's not our symlink target and contains only models
  if [[ -d "${HOME}/.cache/lm-studio" && ! -L "${HOME}/.lmstudio" ]]; then
    local cache_content
    cache_content="$(ls -A "${HOME}/.cache/lm-studio" 2>/dev/null || true)"
    if [[ "$cache_content" == "models" ]]; then
      echo "Cleaning up old .cache/lm-studio directory..."
      rm -rf "${HOME}/.cache/lm-studio"
    fi
  fi
  
  # Remove any existing lms CLI from user's local bin (will be reinstalled via ~/.lmstudio symlink)
  if [[ -x "${HOME}/.local/bin/lms" ]]; then
    echo "Removing old lms CLI from ~/.local/bin..."
    rm -f "${HOME}/.local/bin/lms"
  fi
}

migrate_existing_models

if [[ "${MODEL_ID}" == "auto" ]]; then
  echo "Model auto-selection during install is no longer used. Keeping any existing local model configuration."
  MODEL_ID=""
fi

if [[ -z "${MODEL_ID}" ]]; then
  preserve_existing_model_config
fi

DL_TARGET=""
if [[ -n "${MODEL_ID}" ]]; then
  DL_TARGET="${MODEL_ID}@${QUANTIZATION}"
fi

export DEBIAN_FRONTEND=noninteractive
MISSING_CRITICAL=()
for dep in curl tar unzip; do
  if ! command -v "${dep}" >/dev/null 2>&1; then
    MISSING_CRITICAL+=("${dep}")
  fi
done
PYTHON_BIN=""
if ! PYTHON_BIN="$(select_python_bin)"; then
  MISSING_CRITICAL+=("python3.11-venv or python3.10-venv or python3-venv")
fi
if [[ "${#MISSING_CRITICAL[@]}" -gt 0 ]]; then
  echo "ERROR: Missing critical dependencies: ${MISSING_CRITICAL[*]}"
  echo "These must be in the base distro."
  exit 1
fi

ensure_local_node

log "Zero-sudo dependency check complete."

if [[ -d "${SCRIPT_SOURCE_DIR}/remote_llm_mcp" ]]; then
  mkdir -p "${LOCAL_TOOLS_DIR}"
  rm -rf "${LOCAL_TOOLS_DIR}/remote_llm_mcp"
  cp -a "${SCRIPT_SOURCE_DIR}/remote_llm_mcp" "${LOCAL_TOOLS_DIR}/remote_llm_mcp"
fi

ensure_python_venv "${VENV_DIR}" "Nymphs-Brain"

"${VENV_DIR}/bin/pip" install --upgrade pip requests huggingface_hub

ensure_python_venv "${MCP_VENV_DIR}" "Nymphs-Brain MCP"
"${MCP_VENV_DIR}/bin/pip" install --upgrade pip mcp-proxy web-forager mcpo requests

ensure_python_venv "${OPEN_WEBUI_VENV_DIR}" "Open WebUI"
"${OPEN_WEBUI_VENV_DIR}/bin/pip" install --upgrade pip open-webui

  export npm_config_prefix="${NPM_GLOBAL}"
  
  # Set up LM Studio to use our custom directory
  export LMSTUDIO_HOME="${LMSTUDIO_DIR}"
  
  # Create symlink from ~/.lmstudio to our install directory
  # This ensures the lms CLI stores data in ${INSTALL_ROOT}/lmstudio
  if [[ -L "$HOME/.lmstudio" ]]; then
    # Symlink already exists, remove and recreate to ensure it points to correct location
    rm "$HOME/.lmstudio"
  elif [[ -e "$HOME/.lmstudio" ]]; then
    # Regular file or directory exists, remove it
    rm -rf "$HOME/.lmstudio"
  fi
  
  mkdir -p "${LMSTUDIO_DIR}"
  ln -s "${LMSTUDIO_DIR}" "$HOME/.lmstudio"
  
  echo "Installing/updating LM Studio CLI into ${LMSTUDIO_DIR}..."
  curl -fsSL https://lmstudio.ai/install.sh | bash
  
  # Create symlink so LM Studio sees models in our centralized directory
  # ~/.lmstudio/models → ~/Nymphs-Brain/models
  # This way 'lms get' downloads to our centralized models directory
  mkdir -p "${MODELS_DIR}"
  if [[ -e "$HOME/.lmstudio/models" ]] || [[ -L "$HOME/.lmstudio/models" ]]; then
    rm -rf "$HOME/.lmstudio/models"
  fi
  ln -s "${MODELS_DIR}" "$HOME/.lmstudio/models"
  echo "Linked LM Studio models directory: ~/.lmstudio/models → ${MODELS_DIR}"

# Add our lmstudio bin to PATH
export PATH="${LMSTUDIO_DIR}/bin:${PATH}"

# Detect installation type and handle migration if needed
INSTALL_TYPE=$(detect_installation_type)

case "${INSTALL_TYPE}" in
  "lmstudio-migrate")
    migrate_from_lmstudio
    ;;
  "existing-llama")
    echo ""
    echo "Detected existing llama-server installation, updating..."
    echo ""
    ;;
  "new")
    echo ""
    echo "New installation detected."
    echo ""
    ;;
  "unknown")
    echo ""
    echo "Unknown installation type detected, proceeding with update..."
    echo ""
    ;;
esac

# Install llama-server with CUDA support
echo "Setting up llama-server with CUDA support..."

# Check if already installed from previous build (skip rebuild if binary AND all .so libs present)
if [[ -x "${LOCAL_BIN_DIR}/llama-server" ]] && [[ -f "${LOCAL_BIN_DIR}/libllama-common.so.0" ]] && [[ -f "${LOCAL_BIN_DIR}/libggml-cuda.so.0" ]] && [[ -f "${LOCAL_BIN_DIR}/libggml.so.0" ]]; then
    echo "llama-server already installed at ${LOCAL_BIN_DIR}/llama-server"
else
    if [[ -x "${LOCAL_BIN_DIR}/llama-server" ]]; then
        echo "llama-server binary exists but shared libraries are incomplete, rebuilding..."
    fi
    
    # Need to build from source
    if ! command -v cmake >/dev/null 2>&1; then
        echo "ERROR: cmake is required to build llama-server but not found." >&2
        echo "Please install cmake and try again:" >&2
        echo "  sudo apt-get install cmake" >&2
        exit 1
    fi
    
    LLAMA_CPP_TEMP=""

cleanup_llama_build() {
    if [[ -n "${LLAMA_CPP_TEMP}" && -d "${LLAMA_CPP_TEMP}" ]]; then
        rm -rf "${LLAMA_CPP_TEMP}" 2>/dev/null || true
    fi
}
trap cleanup_llama_build EXIT
    
    echo "cmake detected, building llama-server from source..."
    
    # Only use native Linux CUDA installations at /usr/local/cuda-* (not Windows-mounted /mnt/c paths)
    CUDA_TOOLKIT_ROOT_DIR=""
    
    # Check native Ubuntu/WSL CUDA paths in version order
    for cuda_path in "/usr/local/cuda-13.0" "/usr/local/cuda-12.8" "/usr/local/cuda-12.6" "/usr/local/cuda-12.5" \
                     "/usr/local/cuda-12" "/usr/local/cuda-11.8" "/usr/local/cuda-11" "/usr/local/cuda"; do
        if [[ -d "${cuda_path}" && -x "${cuda_path}/bin/nvcc" ]]; then
            # Verify it's a native ELF binary (not Windows exe via /mnt)
            if file "${cuda_path}/bin/nvcc" 2>/dev/null | grep -q "ELF"; then
                CUDA_TOOLKIT_ROOT_DIR="${cuda_path}"
                break
            fi
        fi
    done
    
    if [[ -n "${CUDA_TOOLKIT_ROOT_DIR}" ]]; then
        echo "Found native CUDA toolkit at: ${CUDA_TOOLKIT_ROOT_DIR}"
        export CUDA_TOOLKIT_ROOT_DIR
        
        NVCC_PATH="${CUDA_TOOLKIT_ROOT_DIR}/bin/nvcc"
        
        # Export the full path to cudart.so (required by cmake)
        if [[ -f "${CUDA_TOOLKIT_ROOT_DIR}/lib64/libcudart.so" ]]; then
            export CUDA_CUDART_LIBRARY="${CUDA_TOOLKIT_ROOT_DIR}/lib64/libcudart.so"
            export CUDA_CUDA_LIBRARY="${CUDA_TOOLKIT_ROOT_DIR}/lib64/libcudart.so"
        else
            echo "WARNING: libcudart.so not found in ${CUDA_TOOLKIT_ROOT_DIR}/lib64"
            CUDA_TOOLKIT_ROOT_DIR=""
        fi
    else
        echo "No native CUDA toolkit found at /usr/local/cuda-*, using bundled archive..."
    fi
    
    if [[ -n "${CUDA_TOOLKIT_ROOT_DIR}" && -d "${CUDA_TOOLKIT_ROOT_DIR}" ]]; then
        # Create temp directory for build
        LLAMA_CPP_TEMP=$(mktemp -d)
        cd "${LLAMA_CPP_TEMP}"
        
        echo "Cloning llama.cpp repository..."
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git .
        
        echo "Configuring build with CUDA (using GGML_CUDA)..."
        
        # Set environment variables to force cmake to use native CUDA only
        export CMAKE_PREFIX_PATH="${CUDA_TOOLKIT_ROOT_DIR}"
        export CMAKE_LIBRARY_PATH="${CUDA_TOOLKIT_ROOT_DIR}/lib64"
        export LD_LIBRARY_PATH="${CUDA_TOOLKIT_ROOT_DIR}/lib64:${LD_LIBRARY_PATH:-}"
        export CUDA_PATH="${CUDA_TOOLKIT_ROOT_DIR}"
        export NVCC="$(dirname "${NVCC_PATH}")/nvcc"
        
        # Create a CMake toolchain file to override autodetection
        cat > "${LLAMA_CPP_TEMP}/toolchain.cmake" <<TOOLCHEOF
# Force native Linux CUDA only, block Windows paths in WSL
set(CMAKE_SYSTEM_NAME Linux)
set(CUDA_TOOLKIT_ROOT_DIR "${CUDA_TOOLKIT_ROOT_DIR}" CACHE PATH "CUDA Toolkit Root" FORCE)
set(CUDA_PATH "${CUDA_TOOLKIT_ROOT_DIR}" CACHE PATH "CUDA Path" FORCE)
set(CMAKE_CUDA_COMPILER "${NVCC_PATH}" CACHE FILEPATH "CUDA Compiler" FORCE)
set(CUDA_CUDART_LIBRARY "${CUDA_CUDART_LIBRARY}" CACHE FILEPATH "CUDA Runtime Library" FORCE)
set(CUDA_CUDA_LIBRARY "${CUDA_CUDART_LIBRARY}" CACHE FILEPATH "CUDA Library" FORCE)
set(CUDA_LIBRARIES "${CUDA_CUDART_LIBRARY}" CACHE FILEPATH "CUDA Libraries" FORCE)
set(CUDA_INCLUDE_DIRS "${CUDA_TOOLKIT_ROOT_DIR}/include" CACHE PATH "CUDA Include Dirs" FORCE)
# Set search modes to only find in specified paths, not elsewhere
set(CMAKE_FIND_ROOT_PATH "${CUDA_TOOLKIT_ROOT_DIR}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TOOLCHEOF
        
        echo "cmake configuration with native CUDA ${CUDA_TOOLKIT_ROOT_DIR}..."
        
        cmake -B build \
            -DCMAKE_TOOLCHAIN_FILE:FILEPATH="${LLAMA_CPP_TEMP}/toolchain.cmake" \
            -DGGML_CUDA=ON \
            -DLLAMA_CUDA=OFF \
            -DGGML_NATIVE=ON \
            -DGPU_ARCHS="70;75;80;86;89;90" \
            -DCMAKE_BUILD_TYPE=Release 2>&1 | tee "${LLAMA_CPP_TEMP}/cmake_output.log"
        
        CMAKE_EXIT_CODE=${PIPESTATUS[0]}
        
        # Verify cmake found our native CUDA
        if [[ -f build/CMakeCache.txt ]]; then
            echo ""
            echo "Checking CMakeCache.txt for CUDA configuration..."
            grep -E "(CUDA_TOOLKIT_ROOT_DIR|CMAKE_CUDA_COMPILER|CUDA_CUDART_LIBRARY)" build/CMakeCache.txt || true
        fi
        
        # Check if we used the correct native CUDA
        if grep -q '/usr/local/cuda-13.0' build/CMakeCache.txt 2>/dev/null; then
            echo "SUCCESS: Using native CUDA from /usr/local/cuda-13.0"
        else
            echo "WARNING: Native CUDA may not have been used correctly."
            echo "cmake output:"
            cat "${LLAMA_CPP_TEMP}/cmake_output.log" 2>/dev/null | tail -20 || true
        fi
        
        echo "Building llama-server (this may take a few minutes)..."
        cmake --build build --config Release -j$(nproc)
        BUILD_RESULT=$?
        
        if [[ ${BUILD_RESULT} -ne 0 ]] || [[ ! -f "build/bin/llama-server" ]]; then
            echo "ERROR: Failed to build llama-server from source." >&2
            exit 1
        fi
        
        mkdir -p "${LOCAL_BIN_DIR}"
        cp build/bin/llama-server "${LOCAL_BIN_DIR}/llama-server"
        chmod +x "${LOCAL_BIN_DIR}/llama-server"
        
        # Copy all required shared libraries (use wildcard to catch all .so files)
        for lib in build/bin/*.so*; do
            if [[ -f "${lib}" ]]; then
                cp "${lib}" "${LOCAL_BIN_DIR}/"
                echo "  Copied: $(basename "${lib}")"
            fi
        done
        
        # Fix RPATH on all binaries and shared libraries so they find each other
        # at runtime regardless of where the temp build dir was
        if ! command -v patchelf >/dev/null 2>&1; then
            echo "patchelf not found, installing..."
            sudo apt-get install -y patchelf >/dev/null 2>&1 || true
        fi
        
        if command -v patchelf >/dev/null 2>&1; then
            for lib in "${LOCAL_BIN_DIR}"/*.so* "${LOCAL_BIN_DIR}"/llama-server; do
                if [[ -f "${lib}" ]]; then
                    patchelf --set-rpath "\$ORIGIN" "${lib}" 2>/dev/null || true
                fi
            done
        fi
        
        echo "llama-server built and installed to ${LOCAL_BIN_DIR}/llama-server"
        
        # Cleanup build directory
        LLAMA_CPP_TEMP=""
        trap - EXIT
        cd - >/dev/null || true
    else
        echo "ERROR: No native CUDA toolkit found at /usr/local/cuda-*" >&2
        echo "Please install NVIDIA CUDA Toolkit and try again." >&2
        exit 1
    fi
fi

echo "Installing MCP helper packages into ${NPM_GLOBAL}"
npm install -g --prefix="${NPM_GLOBAL}" \
  @modelcontextprotocol/server-filesystem \
  @modelcontextprotocol/server-memory \
  @upstash/context7-mcp

ensure_secret_file "${SECRET_DIR}/webui-secret-key" 32
WEBUI_SECRET_KEY="$(tr -d '\r\n' < "${SECRET_DIR}/webui-secret-key")"

if [[ -n "${OPENROUTER_API_KEY}" ]]; then
  {
    printf '%s\n' "# Nymphs-Brain llm-wrapper configuration"
    printf 'OPENROUTER_API_KEY=%s\n' "${OPENROUTER_API_KEY}"
    printf 'REMOTE_LLM_MODEL=%s\n' "deepseek/deepseek-chat"
  } > "${SECRET_DIR}/llm-wrapper.env"
  chmod 600 "${SECRET_DIR}/llm-wrapper.env"
fi

LLM_WRAPPER_ENABLED="0"
if [[ -s "${SECRET_DIR}/llm-wrapper.env" ]] && grep -q '^OPENROUTER_API_KEY=.' "${SECRET_DIR}/llm-wrapper.env"; then
  LLM_WRAPPER_ENABLED="1"
fi
LLM_WRAPPER_MODEL="$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${SECRET_DIR}/llm-wrapper.env" 2>/dev/null | tail -1)"
LLM_WRAPPER_MODEL="${LLM_WRAPPER_MODEL:-deepseek/deepseek-chat}"

cat > "${MCP_CONFIG_DIR}/mcp-proxy-servers.json" <<EOF
{
  "mcpServers": {
    "filesystem": {
      "command": "${LOCAL_NODE_DIR}/bin/node",
      "args": [
        "${NPM_GLOBAL}/lib/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js",
        "${HOME}",
        "${INSTALL_ROOT}"
      ]
    },
    "memory": {
      "command": "${LOCAL_NODE_DIR}/bin/node",
      "args": [
        "${NPM_GLOBAL}/lib/node_modules/@modelcontextprotocol/server-memory/dist/index.js"
      ],
      "env": {
        "MEMORY_FILE_PATH": "${MCP_DATA_DIR}/memory.jsonl"
      }
    },
    "web-forager": {
      "command": "${MCP_VENV_DIR}/bin/web-forager",
      "args": ["serve"]
    },
    "context7": {
      "command": "${LOCAL_NODE_DIR}/bin/node",
      "args": [
        "${NPM_GLOBAL}/lib/node_modules/@upstash/context7-mcp/dist/index.js"
      ]
    },
    "llm-wrapper": {
      "command": "${MCP_VENV_DIR}/bin/python",
      "args": [
        "${INSTALL_ROOT}/local-tools/remote_llm_mcp/cached_llm_mcp_server.py",
        "--model",
        "${LLM_WRAPPER_MODEL}",
        "--timeout",
        "120",
        "--cache-ttl",
        "3600",
        "--cache-dir",
        "${MCP_DATA_DIR}/llm_cache"
      ],
      "env": {
        "OPENROUTER_API_KEY": "$(sed -n 's/^OPENROUTER_API_KEY=//p' "${SECRET_DIR}/llm-wrapper.env" 2>/dev/null | tail -1)",
        "REMOTE_LLM_MODEL": "$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${SECRET_DIR}/llm-wrapper.env" 2>/dev/null | tail -1)"
      }
    }
  }
}
EOF

cat > "${MCP_CONFIG_DIR}/cline-mcp-settings.json" <<EOF
{
  "mcpServers": {
    "filesystem": {
      "url": "http://${MCP_HOST}:${MCP_PORT}/servers/filesystem/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 60
    },
    "memory": {
      "url": "http://${MCP_HOST}:${MCP_PORT}/servers/memory/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 60
    },
    "web-forager": {
      "url": "http://${MCP_HOST}:${MCP_PORT}/servers/web-forager/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 60
    },
    "context7": {
      "url": "http://${MCP_HOST}:${MCP_PORT}/servers/context7/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 60
    },
    "llm-wrapper": {
      "url": "http://${MCP_HOST}:${MCP_PORT}/servers/llm-wrapper/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 120
    }
  }
}
EOF

cat > "${MCP_CONFIG_DIR}/mcpo-servers.json" <<EOF
{
  "mcpServers": {
    "filesystem": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:${MCP_PORT}/servers/filesystem/mcp"
    },
    "memory": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:${MCP_PORT}/servers/memory/mcp"
    },
    "web-forager": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:${MCP_PORT}/servers/web-forager/mcp"
    },
    "context7": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:${MCP_PORT}/servers/context7/mcp"
    },
    "llm-wrapper": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:${MCP_PORT}/servers/llm-wrapper/mcp"
    }
  }
}
EOF

cat > "${MCP_CONFIG_DIR}/open-webui-tool-servers.json" <<EOF
[
  {
    "type": "openapi",
    "url": "http://127.0.0.1:${MCPO_OPENAPI_PORT}/filesystem",
    "path": "openapi.json",
    "spec_type": "url",
    "spec": "",
    "auth_type": "none",
    "key": "",
    "config": { "enable": true },
    "info": {
      "id": "nymphs-brain-filesystem",
      "name": "Nymphs Brain Filesystem",
      "description": "Filesystem tools exposed by Nymphs-Brain mcpo."
    }
  },
  {
    "type": "openapi",
    "url": "http://127.0.0.1:${MCPO_OPENAPI_PORT}/memory",
    "path": "openapi.json",
    "spec_type": "url",
    "spec": "",
    "auth_type": "none",
    "key": "",
    "config": { "enable": true },
    "info": {
      "id": "nymphs-brain-memory",
      "name": "Nymphs Brain Memory",
      "description": "Memory tools exposed by Nymphs-Brain mcpo."
    }
  },
  {
    "type": "openapi",
    "url": "http://127.0.0.1:${MCPO_OPENAPI_PORT}/web-forager",
    "path": "openapi.json",
    "spec_type": "url",
    "spec": "",
    "auth_type": "none",
    "key": "",
    "config": { "enable": true },
    "info": {
      "id": "nymphs-brain-web-forager",
      "name": "Nymphs Brain Web Forager",
      "description": "Web Forager tools exposed by Nymphs-Brain mcpo."
    }
  },
  {
    "type": "openapi",
    "url": "http://127.0.0.1:${MCPO_OPENAPI_PORT}/context7",
    "path": "openapi.json",
    "spec_type": "url",
    "spec": "",
    "auth_type": "none",
    "key": "",
    "config": { "enable": true },
    "info": {
      "id": "nymphs-brain-context7",
      "name": "Nymphs Brain Context7",
      "description": "Context7 documentation tools exposed by Nymphs-Brain mcpo."
    }
  },
  {
    "type": "openapi",
    "url": "http://127.0.0.1:${MCPO_OPENAPI_PORT}/llm-wrapper",
    "path": "openapi.json",
    "spec_type": "url",
    "spec": "",
    "auth_type": "none",
    "key": "",
    "config": { "enable": true },
    "info": {
      "id": "nymphs-brain-llm-wrapper",
      "name": "Nymphs Brain LLM Wrapper",
      "description": "Remote model delegation tools exposed by Nymphs-Brain mcpo."
    }
  }
]
EOF

if [[ "${LLM_WRAPPER_ENABLED}" != "1" ]]; then
  "${PYTHON_BIN}" - "${MCP_CONFIG_DIR}" <<'PYEOF'
import json
import sys
from pathlib import Path

config_dir = Path(sys.argv[1])
for name in ("mcp-proxy-servers.json", "cline-mcp-settings.json", "mcpo-servers.json"):
    path = config_dir / name
    data = json.loads(path.read_text(encoding="utf-8"))
    data.get("mcpServers", {}).pop("llm-wrapper", None)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

path = config_dir / "open-webui-tool-servers.json"
data = json.loads(path.read_text(encoding="utf-8"))
data = [item for item in data if item.get("info", {}).get("id") != "nymphs-brain-llm-wrapper"]
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
fi

cat > "${MCP_CONFIG_DIR}/open-webui-mcp-servers.md" <<EOF
Nymphs-Brain MCP servers for Open WebUI

Open WebUI launch seeds OpenAPI tool server entries automatically from:

- ${MCP_CONFIG_DIR}/open-webui-tool-servers.json

Those entries point at mcpo routes:

- Filesystem: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/filesystem
- Memory: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/memory
- Web Forager: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/web-forager
- Context7: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/context7

If you prefer direct MCP, add these in Admin Settings -> External Tools
Type: MCP (Streamable HTTP)
Auth: None

- Filesystem: http://${MCP_HOST}:${MCP_PORT}/servers/filesystem/mcp
- Memory: http://${MCP_HOST}:${MCP_PORT}/servers/memory/mcp
- Web Forager: http://${MCP_HOST}:${MCP_PORT}/servers/web-forager/mcp
- Context7: http://${MCP_HOST}:${MCP_PORT}/servers/context7/mcp

Notes
- Open WebUI default URL: http://localhost:${OPEN_WEBUI_PORT}
- mcpo default URL: http://localhost:${MCPO_OPENAPI_PORT}
- These endpoints bind to localhost only.
- Cline can use the same endpoints with transport type streamableHttp.
EOF

if [[ "${DOWNLOAD_MODEL}" == "1" && -n "${DL_TARGET}" ]]; then
  if ! command -v lms >/dev/null 2>&1; then
    echo "LM Studio CLI command 'lms' was not found after install." >&2
    echo "Open a new shell or check the LM Studio CLI install output, then rerun this script." >&2
    exit 1
  fi
  echo "Downloading model: ${DL_TARGET}"
  lms get "${DL_TARGET}" --yes
  
  # Stop any LMS server/daemon that may have started during download using proper CLI commands
  echo ""
  echo "Stopping any running LMS daemons..."
  lms server stop 2>/dev/null || true
  lms daemon down 2>/dev/null || true
  
  echo ""
  echo "Model downloaded successfully."
elif [[ "${DOWNLOAD_MODEL}" == "1" ]]; then
  echo "Skipping model download because no local model was specified."
  echo "Use '${BIN_DIR}/lms-model' after install to download/select a local model."
else
  if [[ -n "${DL_TARGET}" ]]; then
    echo "Skipping model download. Configured local model: ${DL_TARGET}."
  else
    echo "No local model configured during install."
    echo "Use '${BIN_DIR}/lms-model' after install to download/select a local model."
  fi
fi

cat > "${INSTALL_ROOT}/nymph-agent.py" <<'PYEOF'
import requests

URL = "http://127.0.0.1:8000/v1/chat/completions"
MODEL = "__MODEL_ID__"


def call(messages):
    try:
        response = requests.post(
            URL,
            json={"model": MODEL, "messages": messages},
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"]
    except Exception as exc:
        return f"Error: {exc}"


history = [
    {
        "role": "system",
        "content": "You are Nymphs-Brain, an experimental local assistant for NymphsCore (llama-server backend).",
    }
]

print("\033[92mNymphs-Brain Agent Active (llama-server on port 8000).\033[0m")
while True:
    try:
        user = input("task> ")
        if user.lower() in {"exit", "quit"}:
            break
        history.append({"role": "user", "content": user})
        output = call(history)
        print(f"AI: {output}")
        history.append({"role": "assistant", "content": output})
    except KeyboardInterrupt:
        break
PYEOF

cat > "${BIN_DIR}/lms-start" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
export PATH="${INSTALL_ROOT}/bin:${INSTALL_ROOT}/local-tools/bin:${INSTALL_ROOT}/local-tools/node/bin:${INSTALL_ROOT}/npm-global/bin:${PATH}"

# Add LM Studio paths for model management tools
for candidate in "${HOME}/.lmstudio/bin" "${HOME}/.cache/lm-studio/bin" "${HOME}/.local/bin"; do
  if [[ -d "${candidate}" ]]; then
    export PATH="${candidate}:${PATH}"
  fi
done

# llama-server path
LLAMA_SERVER="${INSTALL_ROOT}/local-tools/bin/llama-server"

# Model configuration (updated by lms-model script)
MODEL_KEY="__MODEL_ID__"
CONTEXT_LENGTH="__CONTEXT_LENGTH__"

PID_FILE="${INSTALL_ROOT}/logs/lms.pid"
LOG_FILE="${INSTALL_ROOT}/logs/lms.log"

mkdir -p "${INSTALL_ROOT}/logs"

# Stop any existing llama-server instance
if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}")" 2>/dev/null || true
  if kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "Stopping existing llama-server (PID ${old_pid})..."
    kill "$old_pid" >/dev/null 2>&1 || true
    sleep 2
  fi
fi

# Find the actual .gguf file path from our centralized models directory
MODELS_DIR="${INSTALL_ROOT}/models"

if [[ -z "${MODEL_KEY}" ]]; then
  echo "ERROR: No local model is configured." >&2
  echo "Use 'lms-model' to download/select a model first:" >&2
  echo "  ${SCRIPT_DIR}/lms-model" >&2
  exit 1
fi

find_gguf_path() {
  local model_key="$1"
  local model_name="${model_key##*/}"
  local model_slug
  model_slug="$(printf '%s' "${model_name}" | tr '[:upper:]' '[:lower:]' | sed 's/-gguf$//; s/[^a-z0-9]//g')"
  
  if [[ ! -d "${MODELS_DIR}" ]]; then
    echo ""
    return 0
  fi

  # Prefer the real model GGUF, not multimodal projector files.
  gguf_file=$(find "${MODELS_DIR}" -iname "*.gguf" -type f 2>/dev/null | \
              grep -iv 'mmproj' | \
              awk -v model_slug="${model_slug}" '
                {
                  path = tolower($0)
                  comparable = path
                  gsub(/-gguf/, "", comparable)
                  gsub(/[^a-z0-9]/, "", comparable)
                  if (index(comparable, model_slug) > 0) {
                    print
                    exit
                  }
                }')
  if [[ -n "$gguf_file" && -f "$gguf_file" ]]; then
    echo "$gguf_file"
    return 0
  fi
  
  echo ""
}

GGUF_PATH="$(find_gguf_path "${MODEL_KEY}")"

if [[ -z "${GGUF_PATH}" || ! -f "${GGUF_PATH}" ]]; then
  echo "ERROR: Could not find GGUF file for model '${MODEL_KEY}'" >&2
  echo "Use 'lms-model' to download/manage models via LM Studio:" >&2
  echo "  ${SCRIPT_DIR}/lms-model" >&2
  exit 1
fi

# Detect multimodal projector (.mmproj file) next to the GGUF
MMPROJ_FLAG=""
MMPROJ_PATH="$(find "$(dirname "${GGUF_PATH}")" -maxdepth 1 -iname "*mmproj*" -type f 2>/dev/null | head -n1 || true)"
if [[ -n "${MMPROJ_PATH}" && -f "${MMPROJ_PATH}" ]]; then
  MMPROJ_FLAG="--mmproj ${MMPROJ_PATH}"
  echo "Detected multimodal projector: ${MMPROJ_PATH}"
fi

echo "Starting llama-server..."
echo "  Model: ${MODEL_KEY}"
echo "  GGUF Path: ${GGUF_PATH}"
echo "  Context Length: ${CONTEXT_LENGTH}"
if [[ -n "${MMPROJ_FLAG}" ]]; then
  echo "  Multimodal Projector: ${MMPROJ_PATH}"
fi
echo ""

# Ensure shared libraries can be found (fallback if RPATH was not fixed by patchelf)
export LD_LIBRARY_PATH="$(dirname "${LLAMA_SERVER}"):${LD_LIBRARY_PATH:-}"

# Start llama-server with CUDA acceleration
LLAMA_ARGS=(
    -m "${GGUF_PATH}"
    -c "${CONTEXT_LENGTH}"
    -ngl 9999
    --port 8000
    --host "127.0.0.1"
    --flash-attn on
    --parallel 4
    -ctk q8_0
    -ctv q8_0
)
# Append multimodal projector flag if detected
if [[ -n "${MMPROJ_FLAG}" ]]; then
  LLAMA_ARGS+=(--mmproj "${MMPROJ_PATH}")
fi

nohup "${LLAMA_SERVER}" "${LLAMA_ARGS[@]}" > "${LOG_FILE}" 2>&1 &

echo "$!" > "${PID_FILE}"

# Health check
echo "Waiting for llama-server to be ready..."
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:8000/v1/models" >/dev/null 2>&1; then
    echo "llama-server is ready on port 8000"
    echo ""
    echo "API endpoints:"
    echo "  Models:     http://localhost:8000/v1/models"
    echo "  Chat API:   http://localhost:8000/v1/chat/completions"
    echo ""
    echo "Log file: ${LOG_FILE}"
    exit 0
  fi
  sleep 1
done

echo "ERROR: llama-server did not become ready in time." >&2
echo "Check log file: ${LOG_FILE}" >&2
exit 1
WRAPEOF

cat > "${BIN_DIR}/lms-stop" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"

PID_FILE="${INSTALL_ROOT}/logs/lms.pid"
LLM_PORT="${NYMPHS_BRAIN_LLM_PORT:-8000}"

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 0

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi

  kill -TERM "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 2); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  kill -KILL "${pid}" >/dev/null 2>&1 || true
  sleep 0.25
  return 0
}

port_pids() {
  ss -ltnp 2>/dev/null | awk -v target=":${LLM_PORT}" '
    index($4, target) {
      if (match($0, /pid=[0-9]+/)) {
        print substr($0, RSTART + 4, RLENGTH - 4)
      }
    }
  ' | sort -u
}

echo "Stopping llama-server..."

stopped_any=0

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")" 2>/dev/null || true
  if [[ -n "${pid}" ]]; then
    echo "  Stopping PID ${pid}..."
    stop_pid "${pid}"
    stopped_any=1
  fi
fi

while read -r pid; do
  [[ -n "${pid}" ]] || continue
  echo "  Stopping process on port ${LLM_PORT}: ${pid}"
  stop_pid "${pid}"
  stopped_any=1
done < <(port_pids)

rm -f "${PID_FILE}"

if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:${LLM_PORT}/v1/models" >/dev/null 2>&1; then
  echo "llama-server still appears to be running on port ${LLM_PORT}." >&2
  exit 1
fi

if [[ "${stopped_any}" -eq 1 ]]; then
  echo "llama-server stopped."
else
  echo "llama-server is not running."
fi
echo "LM Studio remains available for model management via: ${SCRIPT_DIR}/lms-model"
WRAPEOF

cat > "${BIN_DIR}/lms-status" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
PID_FILE="${INSTALL_ROOT}/logs/lms.pid"
LOG_FILE="${INSTALL_ROOT}/logs/lms.log"

echo "llama-server status:"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")" 2>/dev/null || echo "unknown"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "  Process: running (PID ${pid})"
  else
    echo "  Process: stopped (stale PID file)"
  fi
else
  echo "  Process: no PID file found"
fi

if curl -fsS "http://127.0.0.1:8000/v1/models" >/dev/null 2>&1; then
  echo "  API: responding on port 8000"
  
  MODEL_INFO=$(curl -fsS "http://127.0.0.1:8000/v1/models" 2>/dev/null | \
               python3 -c "import sys,json; d=json.load(sys.stdin); models=d.get('data',[]); print(models[0]['id'] if models else 'none')" 2>/dev/null || echo "unknown")
  echo "  Model loaded: ${MODEL_INFO}"
else
  echo "  API: not responding"
fi

echo ""
echo "Log file: ${LOG_FILE}"
echo "Last 5 lines of log:"
if [[ -f "${LOG_FILE}" ]]; then
  tail -n 5 "${LOG_FILE}" | sed 's/^/  /'
else
  echo "  (no log file found)"
fi
WRAPEOF

cat > "${BIN_DIR}/lms-update" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

echo "LM Studio CLI remains available for model management."
echo "Nymphs-Brain runtime updates are handled by Update Stack via brain-refresh."
echo "No LM Studio server update is required for the llama-server backend."
WRAPEOF

cat > "${BIN_DIR}/lms-model" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"

python_json() {
  if [[ -x "${INSTALL_ROOT}/venv/bin/python3" ]]; then
    "${INSTALL_ROOT}/venv/bin/python3" "$@"
  else
    python3 "$@"
  fi
}

export PATH="${INSTALL_ROOT}/bin:${INSTALL_ROOT}/local-tools/bin:${INSTALL_ROOT}/local-tools/node/bin:${INSTALL_ROOT}/npm-global/bin:${PATH}"
for candidate in "${HOME}/.lmstudio/bin" "${HOME}/.cache/lm-studio/bin" "${HOME}/.local/bin"; do
  if [[ -d "${candidate}" ]]; then
    export PATH="${candidate}:${PATH}"
  fi
done

LMS_BIN="$(command -v lms || true)"

declare -A CONTEXT_SIZES=(
  ["1"]="2048"
  ["2"]="4096"
  ["3"]="8192"
  ["4"]="16384"
  ["5"]="32768"
  ["6"]="49152"
  ["7"]="65536"
  ["8"]="98304"
  ["9"]="131072"
  ["10"]="262144"
)

CONTEXT_LABELS=(
  "2k   (2048)"
  "4k   (4096)"
  "8k   (8192)"
  "16k  (16384)"
  "32k  (32768)"
  "48k  (49152)"
  "64k  (65536)"
  "96k  (98304)"
  "128k (131072)"
  "256k (262144)"
  "Custom (user input)"
)

SELECTED_CONTEXT_SIZE=""
SELECTED_MODEL_KEY=""
REMOTE_MODEL_FILE="${INSTALL_ROOT}/secrets/llm-wrapper.env"

json_model_keys() {
  python_json -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = []

if isinstance(data, dict):
    for key in ("models", "llms", "data"):
        if isinstance(data.get(key), list):
            data = data[key]
            break
    else:
        data = []

for item in data if isinstance(data, list) else []:
    if isinstance(item, dict):
        model_key = item.get("modelKey") or item.get("key") or item.get("id")
        if model_key:
            print(model_key)
'
}

lms_model_keys() {
  local model_json
  model_json="$("${LMS_BIN}" ls --llm --json 2>/dev/null || printf '[]')"
  printf '%s' "${model_json}" | json_model_keys
}

ensure_lms() {
  if [[ -z "${LMS_BIN:-}" ]] || [[ ! -x "${LMS_BIN}" ]]; then
    echo "LM Studio CLI command 'lms' was not found." >&2
    echo "Rerun install_nymphs_brain.sh or check the LM Studio CLI installation." >&2
    exit 1
  fi
}

check_model_downloaded() {
  local model_key="$1"
  # The lms ls command will only show downloaded models, so if we find it, it's ready
  local model_list
  model_list="$("${LMS_BIN}" ls --llm --json 2>/dev/null || printf '[]')"
  echo "$model_list" | python_json -c "
import json, sys
data = json.load(sys.stdin)
target = '${1}'
if isinstance(data, dict):
    for key in ('models', 'llms', 'data'):
        if isinstance(data.get(key), list):
            data = data[key]
            break
else:
    data = []
found = any(
    isinstance(item, dict) and str(item.get('modelKey') or item.get('key') or item.get('id')) == target
    for item in data if isinstance(data, list)
)
sys.exit(0 if found else 1)
" 2>/dev/null
}

model_is_probably_vision() {
  local model_key="$1"
  local normalized
  normalized="$(printf '%s' "${model_key}" | tr '[:upper:]' '[:lower:]')"

  case "${normalized}" in
    *-vl-*|*vision*|*llava*|*minicpmv*|*internvl*|*cogvlm*|*pixtral*|*glm4v*|*gemma4v*|*qwen2vl*|*qwen3vl*|*molmo*|*smolvlm*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_downloaded_model_dir() {
  local model_key="$1"
  local model_name="${model_key##*/}"
  local model_slug
  model_slug="$(printf '%s' "${model_name}" | tr '[:upper:]' '[:lower:]' | sed 's/-gguf$//; s/[^a-z0-9]//g')"

  if [[ ! -d "${INSTALL_ROOT}/models" ]]; then
    return 1
  fi

  find "${INSTALL_ROOT}/models" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | \
    awk -v model_slug="${model_slug}" '
      {
        path = tolower($0)
        comparable = path
        gsub(/-gguf/, "", comparable)
        gsub(/[^a-z0-9]/, "", comparable)
        if (index(comparable, model_slug) > 0) {
          print
          exit
        }
      }'
}

find_mmproj_for_model_dir() {
  local model_dir="$1"
  find "${model_dir}" -maxdepth 1 -type f \( -iname '*mmproj*' -o -iname '*projector*' \) 2>/dev/null | head -n 1 || true
}

ensure_mmproj_for_model() {
  local model_key="$1"
  local model_dir=""
  local mmproj_path=""
  local vendor=""
  local folder=""

  if ! model_is_probably_vision "${model_key}"; then
    return 0
  fi

  model_dir="$(find_downloaded_model_dir "${model_key}" || true)"
  if [[ -z "${model_dir}" || ! -d "${model_dir}" ]]; then
    echo "Vision model detected, but the downloaded model folder could not be located yet."
    return 0
  fi

  mmproj_path="$(find_mmproj_for_model_dir "${model_dir}")"
  if [[ -n "${mmproj_path}" && -f "${mmproj_path}" ]]; then
    echo "Vision projector already present: $(basename "${mmproj_path}")"
    return 0
  fi

  vendor="$(basename "$(dirname "${model_dir}")")"
  folder="$(basename "${model_dir}")"

  echo "Vision model detected. Looking for a matching mmproj file..."
  if python_json - "${model_dir}" "${model_key}" "${vendor}/${folder}" <<'PYEOF'
import os
import shutil
import sys

from huggingface_hub import HfApi, hf_hub_download

model_dir = sys.argv[1]
model_key = sys.argv[2]
repo_candidates = []
for candidate in sys.argv[3:]:
    if candidate and candidate not in repo_candidates:
        repo_candidates.append(candidate)

if model_key and model_key not in repo_candidates:
    repo_candidates.append(model_key)

api = HfApi()

for repo_id in repo_candidates:
    try:
        files = api.list_repo_files(repo_id=repo_id, repo_type="model")
    except Exception:
        continue

    mmproj_files = [
        file_name for file_name in files
        if "mmproj" in file_name.lower() and file_name.lower().endswith(".gguf")
    ]

    if not mmproj_files:
        continue

    mmproj_files.sort(key=lambda value: (
        0 if "/" not in value else 1,
        0 if "model-f16" in value.lower() else 1,
        len(value),
        value.lower(),
    ))

    selected = mmproj_files[0]
    cached_path = hf_hub_download(repo_id=repo_id, filename=selected, repo_type="model")
    destination = os.path.join(model_dir, os.path.basename(selected))
    shutil.copy2(cached_path, destination)
    print(f"Downloaded mmproj from {repo_id}: {os.path.basename(destination)}")
    sys.exit(0)

print("No matching mmproj file was found automatically.")
sys.exit(1)
PYEOF
  then
    mmproj_path="$(find_mmproj_for_model_dir "${model_dir}")"
    if [[ -n "${mmproj_path}" && -f "${mmproj_path}" ]]; then
      echo "Vision projector ready: $(basename "${mmproj_path}")"
    fi
  else
    echo "Warning: could not auto-download an mmproj file for ${model_key}."
    echo "Image input may not work until a matching projector file is placed beside the GGUF."
  fi
}

select_context_size() {
  local choice

  while true; do
    echo
    echo "Select context size:"
    for i in "${!CONTEXT_LABELS[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "${CONTEXT_LABELS[i]}"
    done
    echo
    read -rp "Enter your choice (1-11): " choice

    # Custom context size (option 11)
    if [[ "$choice" == "11" ]]; then
      read -rp "Enter custom context size (tokens, min 512): " SELECTED_CONTEXT_SIZE
      if [[ "${SELECTED_CONTEXT_SIZE}" =~ ^[0-9]+$ ]] && [[ "${SELECTED_CONTEXT_SIZE}" -ge 512 ]]; then
        echo "Selected custom context size: ${SELECTED_CONTEXT_SIZE} tokens"
        return 0
      else
        echo "Invalid context size. Must be a number >= 512."
        continue
      fi
    fi

    if [[ -n "${CONTEXT_SIZES[$choice]:-}" ]]; then
      SELECTED_CONTEXT_SIZE="${CONTEXT_SIZES[$choice]}"
      echo "Selected context size: ${SELECTED_CONTEXT_SIZE} tokens"
      return 0
    fi

    echo "Invalid choice. Please enter a number from 1 to 11."
  done
}

confirm_model() {
  local response

  while true; do
    read -rp "Use this model? (y/n/change): " response
    case "${response}" in
      y|Y|yes|Yes)
        echo
        return 0
        ;;
      n|N|no|No)
        echo "Exiting without loading a model."
        exit 0
        ;;
      c|C|change|Change)
        echo "Returning to model selection..."
        return 1
        ;;
      *)
        echo "Please enter 'y', 'n', or 'change'."
        ;;
    esac
  done
}

choose_downloaded_model() {
  local prompt="$1"
  mapfile -t model_keys < <(lms_model_keys)

  if [[ "${#model_keys[@]}" -eq 0 ]]; then
    echo "No downloaded models were found."
    return 1
  fi

  echo "${prompt}"
  select model_choice in "${model_keys[@]}"; do
    if [[ -n "${model_choice}" ]]; then
      SELECTED_MODEL_KEY="${model_choice}"
      return 0
    fi
    echo "Invalid selection. Please try again."
  done
}

capture_selected_model() {
  local search_query="$1"
  local before_keys
  local after_keys
  local new_model_key

  before_keys="$(lms_model_keys | sort || true)"

  if [[ -n "${search_query}" ]]; then
    echo "Searching for models matching: ${search_query}"
    "${LMS_BIN}" get "${search_query}" --select
  else
    echo "Showing available models..."
    "${LMS_BIN}" get --select
  fi

  after_keys="$(lms_model_keys | sort || true)"
  new_model_key="$(comm -13 <(printf '%s\n' "${before_keys}") <(printf '%s\n' "${after_keys}") || true)"
  new_model_key="${new_model_key%%$'\n'*}"

  SELECTED_MODEL_KEY=""
  if [[ -n "${new_model_key}" ]]; then
    SELECTED_MODEL_KEY="${new_model_key}"
    echo "Selected new model: ${SELECTED_MODEL_KEY}"
    return 0
  fi

  choose_downloaded_model "Select the downloaded model to use:"
}

update_lms_start_script() {
  local model_key="$1"
  local context_size="$2"
  local lms_start_path="${INSTALL_ROOT}/bin/lms-start"

  if [[ ! -f "${lms_start_path}" ]]; then
    echo "Warning: lms-start was not found at ${lms_start_path}."
    return 0
  fi

  # Use awk for robust replacement that handles CRLF line endings
  awk -v model="${model_key}" \
      -v context="${context_size}" '
    BEGIN { RS=ORS="\n" }
    {
      gsub(/\r$/, "")  # Strip CRLF if present
      if (/^MODEL_KEY=/) {
        print "MODEL_KEY=\"" model "\""
        next
      }
      if (/^CONTEXT_LENGTH=/) {
        print "CONTEXT_LENGTH=" context
        next
      }
      print
    }
    ' "${lms_start_path}" > "${lms_start_path}.tmp"

  mv "${lms_start_path}.tmp" "${lms_start_path}"
  chmod +x "${lms_start_path}"
  echo "Updated lms-start with model: ${model_key} and context: ${context_size} for llama-server."
}

update_agent_script() {
  local model_key="$1"
  local agent_path="${INSTALL_ROOT}/nymph-agent.py"
  local model_literal

  if [[ ! -f "${agent_path}" ]]; then
    return 0
  fi

  model_literal="$(python_json -c 'import json, sys; print(json.dumps(sys.argv[1]))' "${model_key}")"
  awk -v model_literal="${model_literal}" '
    /^MODEL = / { print "MODEL = " model_literal; next }
    { print }
  ' "${agent_path}" > "${agent_path}.tmp"
  mv "${agent_path}.tmp" "${agent_path}"
  echo "Updated nymph-chat to request the selected model."
}

stop_lmstudio_daemon() {
  echo "Stopping LM Studio daemon..."
  lms server stop 2>/dev/null || true
  lms daemon down 2>/dev/null || true
  # Fallback: kill any remaining LM Studio server/daemon processes
  pkill -f "lms.*server" 2>/dev/null || true
  pkill -f "lms.*daemon" 2>/dev/null || true
  sleep 1
  echo "LM Studio daemon stopped."
}

finalize_selected_model() {
  select_context_size

  echo
  echo "Updating lms-start configuration:"
  echo "  model: ${SELECTED_MODEL_KEY}"
  echo "  context: ${SELECTED_CONTEXT_SIZE}"

  ensure_mmproj_for_model "${SELECTED_MODEL_KEY}"
  update_lms_start_script "${SELECTED_MODEL_KEY}" "${SELECTED_CONTEXT_SIZE}"
  update_agent_script "${SELECTED_MODEL_KEY}"
  
  echo ""
  echo "Configuration updated successfully."
  
  # Stop the LM Studio daemon that was started for model selection
  stop_lmstudio_daemon
  
  echo ""
  echo "To start the server with this model, run:"
  echo "  ${INSTALL_ROOT}/bin/lms-start"
}

clear_local_model() {
  local lms_start_path="${INSTALL_ROOT}/bin/lms-start"

  if [[ ! -f "${lms_start_path}" ]]; then
    echo "Warning: lms-start was not found at ${lms_start_path}."
    return 0
  fi

  awk '
    BEGIN { RS=ORS="\n" }
    {
      gsub(/\r$/, "")
      if (/^MODEL_KEY=/) {
        print "MODEL_KEY=\"\""
        next
      }
      print
    }
  ' "${lms_start_path}" > "${lms_start_path}.tmp"

  mv "${lms_start_path}.tmp" "${lms_start_path}"
  chmod +x "${lms_start_path}"
  echo "Local model cleared."
}

set_remote_model_menu() {
  local current_key=""
  local current_model=""
  local new_model=""

  mkdir -p "$(dirname "${REMOTE_MODEL_FILE}")"
  if [[ -f "${REMOTE_MODEL_FILE}" ]]; then
    current_key="$(sed -n 's/^OPENROUTER_API_KEY=//p' "${REMOTE_MODEL_FILE}" | tail -1)"
    current_model="$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${REMOTE_MODEL_FILE}" | tail -1)"
  fi

  echo
  echo "Set Remote llm-wrapper Model"
  echo "Current remote model: ${current_model:-deepseek/deepseek-chat}"
  read -rp "Enter remote model id [deepseek/deepseek-chat]: " new_model
  new_model="${new_model:-deepseek/deepseek-chat}"

  {
    printf '%s\n' "# Nymphs-Brain llm-wrapper configuration"
    if [[ -n "${current_key}" ]]; then
      printf 'OPENROUTER_API_KEY=%s\n' "${current_key}"
    fi
    printf 'REMOTE_LLM_MODEL=%s\n' "${new_model}"
  } > "${REMOTE_MODEL_FILE}"
  chmod 600 "${REMOTE_MODEL_FILE}"
  echo "Remote llm-wrapper model set to: ${new_model}"
}

use_downloaded_model_menu() {
  local retry=true

  echo
  echo "Use Downloaded Model"

  while "${retry}"; do
    if ! choose_downloaded_model "Select a downloaded model to use:"; then
      return
    fi
    if ! confirm_model; then
      retry=true
      continue
    fi
    retry=false
  done

  finalize_selected_model
}

remove_models_menu() {
  while true; do
    echo
    echo "Remove Models"
    mapfile -t model_keys < <(lms_model_keys)

    if [[ "${#model_keys[@]}" -eq 0 ]]; then
      echo "No models to remove."
      return
    fi

    select model_choice in "${model_keys[@]}" "Back to Main Menu"; do
      if [[ "${model_choice}" == "Back to Main Menu" ]]; then
        return
      fi

      if [[ -n "${model_choice}" ]]; then
        read -rp "Remove '${model_choice}'? (y/n): " response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
          "${LMS_BIN}" rm "${model_choice}"
          echo "Removed ${model_choice}."
        fi
        break
      fi

      echo "Invalid selection. Please try again."
    done
  done
}

run_add_change_model() {
  local search_query="$1"
  local retry=true

  echo
  echo "Download New Model"

  while "${retry}"; do
    capture_selected_model "${search_query}"
    if ! confirm_model; then
      retry=true
      continue
    fi
    retry=false
  done

  finalize_selected_model
}

main() {
  ensure_lms

  if [[ "$#" -gt 0 ]]; then
    run_add_change_model "$*"
    return
  fi

  while true; do
    echo
    echo "Nymphs-Brain Model Manager"
    echo "1) Set Local Model From Downloaded"
    echo "2) Download New Local Model"
    echo "3) Clear Local Model"
    echo "4) Set Remote llm-wrapper Model"
    echo "5) Remove Local Models"
    echo "6) Exit"
    echo
    read -rp "Enter your choice (1-6): " choice

    case "${choice}" in
      1) use_downloaded_model_menu ;;
      2) run_add_change_model "" ;;
      3) clear_local_model ;;
      4) set_remote_model_menu ;;
      5) remove_models_menu ;;
      6) return ;;
      *) echo "Invalid choice. Please try again." ;;
    esac
  done
}

main "$@"
WRAPEOF

cat > "${BIN_DIR}/mcp-start" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
MCP_VENV_DIR="${INSTALL_ROOT}/mcp-venv"
MCP_CONFIG_DIR="${INSTALL_ROOT}/mcp/config"
MCP_LOG_DIR="${INSTALL_ROOT}/mcp/logs"
SECRET_DIR="${INSTALL_ROOT}/secrets"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-__MCP_HOST__}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-__MCP_PORT__}}"
MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-__MCPO_OPENAPI_PORT__}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-__OPEN_WEBUI_PORT__}"
PID_FILE="${MCP_LOG_DIR}/mcp-proxy.pid"
LOG_FILE="${MCP_LOG_DIR}/mcp-proxy.log"
MCPO_PID_FILE="${MCP_LOG_DIR}/mcpo.pid"
MCPO_LOG_FILE="${MCP_LOG_DIR}/mcpo.log"
MCPO_CONFIG_FILE="${MCP_CONFIG_DIR}/mcpo-servers.json"

is_running() {
  [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1
}

is_mcpo_running() {
  [[ -f "${MCPO_PID_FILE}" ]] && kill -0 "$(cat "${MCPO_PID_FILE}")" >/dev/null 2>&1
}

mkdir -p "${MCP_LOG_DIR}"

if is_running; then
  echo "Nymphs-Brain MCP gateway is already running at http://${MCP_HOST}:${MCP_PORT}"
elif [[ ! -x "${MCP_VENV_DIR}/bin/mcp-proxy" ]]; then
  echo "mcp-proxy is not installed at ${MCP_VENV_DIR}/bin/mcp-proxy. Rerun install_nymphs_brain.sh." >&2
  exit 1
else
  echo "Starting Nymphs-Brain MCP gateway at http://${MCP_HOST}:${MCP_PORT}"
  nohup "${MCP_VENV_DIR}/bin/mcp-proxy" \
    --host "${MCP_HOST}" \
    --port "${MCP_PORT}" \
    --allow-origin "http://localhost:${OPEN_WEBUI_PORT}" \
    --allow-origin "http://127.0.0.1:${OPEN_WEBUI_PORT}" \
    --named-server-config "${MCP_CONFIG_DIR}/mcp-proxy-servers.json" \
    > "${LOG_FILE}" 2>&1 &

  echo "$!" > "${PID_FILE}"

  sleep 2

  if ! is_running; then
    echo "MCP gateway exited while starting. See ${LOG_FILE}" >&2
    exit 1
  fi

  for _ in $(seq 1 16); do
    if curl -fsS "http://${MCP_HOST}:${MCP_PORT}/status" >/dev/null 2>&1 ||
       curl -fsS "http://${MCP_HOST}:${MCP_PORT}/" >/dev/null 2>&1; then
      echo "Nymphs-Brain MCP gateway is ready."
      break
    fi
    sleep 0.25
  done
fi

if is_mcpo_running; then
  echo "Nymphs-Brain mcpo OpenAPI bridge is already running at http://${MCP_HOST}:${MCPO_OPENAPI_PORT}"
  exit 0
fi

if [[ ! -x "${MCP_VENV_DIR}/bin/mcpo" ]]; then
  echo "mcpo is not installed at ${MCP_VENV_DIR}/bin/mcpo. Rerun install_nymphs_brain.sh." >&2
  exit 1
fi

if [[ ! -f "${MCPO_CONFIG_FILE}" ]]; then
  echo "mcpo config is missing at ${MCPO_CONFIG_FILE}. Rerun install_nymphs_brain.sh." >&2
  exit 1
fi

echo "Starting Nymphs-Brain mcpo OpenAPI bridge at http://${MCP_HOST}:${MCPO_OPENAPI_PORT}"
nohup "${MCP_VENV_DIR}/bin/mcpo" \
  --host "${MCP_HOST}" \
  --port "${MCPO_OPENAPI_PORT}" \
  --config "${MCPO_CONFIG_FILE}" \
  > "${MCPO_LOG_FILE}" 2>&1 &

echo "$!" > "${MCPO_PID_FILE}"

for _ in $(seq 1 60); do
  if curl -fsS "http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/filesystem/openapi.json" >/dev/null 2>&1; then
    echo "Nymphs-Brain mcpo OpenAPI bridge is ready."
    echo "  Filesystem API: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/filesystem"
    echo "  Memory API:     http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/memory"
    echo "  Web Forager:    http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/web-forager"
    echo "  Context7 API:   http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/context7"
    exit 0
  fi
  sleep 1
done

echo "mcpo did not become ready in time. See ${MCPO_LOG_FILE}" >&2
exit 1
WRAPEOF

cat > "${BIN_DIR}/mcp-stop" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-__MCP_HOST__}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-__MCP_PORT__}}"
MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-__MCPO_OPENAPI_PORT__}"
PID_FILE="${INSTALL_ROOT}/mcp/logs/mcp-proxy.pid"
MCPO_PID_FILE="${INSTALL_ROOT}/mcp/logs/mcpo.pid"

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 0

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi

  kill -TERM "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 2); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  kill -KILL "${pid}" >/dev/null 2>&1 || true
  sleep 0.25
  return 0
}

port_pids() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v target=":${port}" '
    index($4, target) {
      if (match($0, /pid=[0-9]+/)) {
        print substr($0, RSTART + 4, RLENGTH - 4)
      }
    }
  ' | sort -u
}

echo "Stopping Nymphs-Brain MCP services..."

stopped_any=0

for pid_file in "${MCPO_PID_FILE}" "${PID_FILE}"; do
  if [[ -f "${pid_file}" ]]; then
    stop_pid "$(cat "${pid_file}" 2>/dev/null || true)"
    stopped_any=1
  fi
done

for port in "${MCPO_OPENAPI_PORT}" "${MCP_PORT}"; do
  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    stop_pid "${pid}"
    stopped_any=1
  done < <(port_pids "${port}")
done

rm -f "${PID_FILE}" "${MCPO_PID_FILE}"

if curl -fsS --connect-timeout 1 --max-time 2 "http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/filesystem/openapi.json" >/dev/null 2>&1 ||
   curl -fsS --connect-timeout 1 --max-time 2 "http://${MCP_HOST}:${MCP_PORT}/status" >/dev/null 2>&1 ||
   curl -fsS --connect-timeout 1 --max-time 2 "http://${MCP_HOST}:${MCP_PORT}/" >/dev/null 2>&1; then
  echo "MCP services still appear to be running." >&2
  exit 1
fi

if [[ "${stopped_any}" -eq 1 ]]; then
  echo "Nymphs-Brain MCP services stopped."
else
  echo "Nymphs-Brain MCP services are not running."
fi
WRAPEOF

cat > "${BIN_DIR}/mcp-status" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-__MCP_HOST__}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-__MCP_PORT__}}"
MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-__MCPO_OPENAPI_PORT__}"
PID_FILE="${INSTALL_ROOT}/mcp/logs/mcp-proxy.pid"
MCPO_PID_FILE="${INSTALL_ROOT}/mcp/logs/mcpo.pid"

if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  echo "MCP proxy: running"
elif ss -ltn 2>/dev/null | awk -v target=":${MCP_PORT}" 'index($4, target) { found=1 } END { exit(found ? 0 : 1) }'; then
  echo "MCP proxy: running"
else
  echo "MCP proxy: stopped"
fi

if [[ -f "${MCPO_PID_FILE}" ]] && kill -0 "$(cat "${MCPO_PID_FILE}")" >/dev/null 2>&1; then
  echo "mcpo OpenAPI: running"
elif ss -ltn 2>/dev/null | awk -v target=":${MCPO_OPENAPI_PORT}" 'index($4, target) { found=1 } END { exit(found ? 0 : 1) }'; then
  echo "mcpo OpenAPI: running"
else
  echo "mcpo OpenAPI: stopped"
fi

echo "MCP gateway URL: http://${MCP_HOST}:${MCP_PORT}"
echo "MCP status URL: http://${MCP_HOST}:${MCP_PORT}/status"
echo "mcpo OpenAPI URL: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}"
echo "Streamable HTTP endpoints:"
echo "- filesystem: http://${MCP_HOST}:${MCP_PORT}/servers/filesystem/mcp"
echo "- memory: http://${MCP_HOST}:${MCP_PORT}/servers/memory/mcp"
echo "- web-forager: http://${MCP_HOST}:${MCP_PORT}/servers/web-forager/mcp"
echo "- context7: http://${MCP_HOST}:${MCP_PORT}/servers/context7/mcp"
echo "Legacy SSE endpoints:"
echo "- filesystem: http://${MCP_HOST}:${MCP_PORT}/servers/filesystem/sse"
echo "- memory: http://${MCP_HOST}:${MCP_PORT}/servers/memory/sse"
echo "- web-forager: http://${MCP_HOST}:${MCP_PORT}/servers/web-forager/sse"
echo "OpenAPI tool routes:"
echo "- filesystem: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/filesystem/docs"
echo "- memory: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/memory/docs"
echo "- web-forager: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/web-forager/docs"
echo "- context7: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}/context7/docs"
echo "MCP config: ${INSTALL_ROOT}/mcp/config/mcp-proxy-servers.json"
echo "mcpo config: ${INSTALL_ROOT}/mcp/config/mcpo-servers.json"
echo "Cline config template: ${INSTALL_ROOT}/mcp/config/cline-mcp-settings.json"
echo "Open WebUI setup note: ${INSTALL_ROOT}/mcp/config/open-webui-mcp-servers.md"
WRAPEOF

cat > "${BIN_DIR}/open-webui-start" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
OPEN_WEBUI_VENV_DIR="${INSTALL_ROOT}/open-webui-venv"
OPEN_WEBUI_DATA_DIR="${INSTALL_ROOT}/open-webui-data"
OPEN_WEBUI_LOG_DIR="${OPEN_WEBUI_DATA_DIR}/logs"
SECRET_DIR="${INSTALL_ROOT}/secrets"
OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-__OPEN_WEBUI_HOST__}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-__OPEN_WEBUI_PORT__}"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-__MCP_HOST__}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-__MCP_PORT__}}"
MCPO_OPENAPI_PORT="${NYMPHS_BRAIN_MCPO_OPENAPI_PORT:-__MCPO_OPENAPI_PORT__}"
LLM_API_BASE_URL="${NYMPHS_BRAIN_LLM_API_BASE_URL:-http://127.0.0.1:8000/v1}"
PID_FILE="${OPEN_WEBUI_LOG_DIR}/open-webui.pid"
LOG_FILE="${OPEN_WEBUI_LOG_DIR}/open-webui.log"
WEBUI_SECRET_KEY_FILE="${SECRET_DIR}/webui-secret-key"
TOOL_SERVER_CONNECTIONS_FILE="${INSTALL_ROOT}/mcp/config/open-webui-tool-servers.json"

is_running() {
  [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1
}

seed_tool_server_connections() {
  if [[ ! -f "${TOOL_SERVER_CONNECTIONS_FILE}" ]]; then
    echo "Open WebUI tool server seed file is missing at ${TOOL_SERVER_CONNECTIONS_FILE}. Rerun install_nymphs_brain.sh." >&2
    return 1
  fi

  DATA_DIR="${OPEN_WEBUI_DATA_DIR}" TOOL_SERVER_CONNECTIONS_FILE="${TOOL_SERVER_CONNECTIONS_FILE}" \
    "${OPEN_WEBUI_VENV_DIR}/bin/python3" - <<'PYEOF'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["TOOL_SERVER_CONNECTIONS_FILE"]).read_text(encoding="utf-8"))

from open_webui.config import ENABLE_DIRECT_CONNECTIONS, TOOL_SERVER_CONNECTIONS

managed_ids = {
    item.get("info", {}).get("id")
    for item in payload
    if item.get("info", {}).get("id")
}

current = list(TOOL_SERVER_CONNECTIONS.value or [])
preserved = [
    item
    for item in current
    if item.get("info", {}).get("id") not in managed_ids
]
merged = preserved + payload

if current != merged:
    TOOL_SERVER_CONNECTIONS.value = merged
    TOOL_SERVER_CONNECTIONS.save()

if ENABLE_DIRECT_CONNECTIONS.value is not True:
    ENABLE_DIRECT_CONNECTIONS.value = True
    ENABLE_DIRECT_CONNECTIONS.save()
PYEOF
}

mkdir -p "${OPEN_WEBUI_LOG_DIR}"

if is_running; then
  echo "Open WebUI is already running at http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}"
  exit 0
fi

if [[ ! -x "${OPEN_WEBUI_VENV_DIR}/bin/open-webui" ]]; then
  echo "Open WebUI is not installed at ${OPEN_WEBUI_VENV_DIR}/bin/open-webui. Rerun install_nymphs_brain.sh." >&2
  exit 1
fi

if [[ ! -s "${WEBUI_SECRET_KEY_FILE}" ]]; then
  echo "Open WebUI secret key is missing at ${WEBUI_SECRET_KEY_FILE}. Rerun install_nymphs_brain.sh." >&2
  exit 1
fi

"${SCRIPT_DIR}/mcp-start"
seed_tool_server_connections

WEBUI_SECRET_KEY="$(tr -d '\r\n' < "${WEBUI_SECRET_KEY_FILE}")"

echo "Starting Open WebUI at http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}"
nohup env \
  DATA_DIR="${OPEN_WEBUI_DATA_DIR}" \
  WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY}" \
  ENABLE_DIRECT_CONNECTIONS="True" \
  OPENAI_API_BASE_URL="${LLM_API_BASE_URL}" \
  OPENAI_API_KEY="nymphs-brain" \
  UVICORN_WORKERS="1" \
  "${OPEN_WEBUI_VENV_DIR}/bin/open-webui" serve \
    --host "${OPEN_WEBUI_HOST}" \
    --port "${OPEN_WEBUI_PORT}" \
  > "${LOG_FILE}" 2>&1 &

echo "$!" > "${PID_FILE}"

for _ in $(seq 1 90); do
  if curl -fsS "http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}" >/dev/null 2>&1; then
    echo "Open WebUI is ready."
    echo "Open this URL from Windows: http://localhost:${OPEN_WEBUI_PORT}"
    echo "Brain OpenAPI tool servers were seeded automatically from:"
    echo "${TOOL_SERVER_CONNECTIONS_FILE}"
    echo "mcpo base URL: http://${MCP_HOST}:${MCPO_OPENAPI_PORT}"
    exit 0
  fi
  sleep 1
done

echo "Open WebUI did not become ready in time. See ${LOG_FILE}" >&2
exit 1
WRAPEOF

cat > "${BIN_DIR}/open-webui-stop" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-__OPEN_WEBUI_HOST__}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-__OPEN_WEBUI_PORT__}"
PID_FILE="${INSTALL_ROOT}/open-webui-data/logs/open-webui.pid"

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 0

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  kill -9 "${pid}" >/dev/null 2>&1 || true
}

port_pids() {
  ss -ltnp 2>/dev/null | awk -v target=":${OPEN_WEBUI_PORT}" '
    index($4, target) {
      if (match($0, /pid=[0-9]+/)) {
        print substr($0, RSTART + 4, RLENGTH - 4)
      }
    }
  ' | sort -u
}

echo "Stopping Open WebUI..."

stopped_any=0

if [[ -f "${PID_FILE}" ]]; then
  stop_pid "$(cat "${PID_FILE}" 2>/dev/null || true)"
  stopped_any=1
fi

while read -r pid; do
  [[ -n "${pid}" ]] || continue
  stop_pid "${pid}"
  stopped_any=1
done < <(port_pids)

rm -f "${PID_FILE}"

if curl -fsS --connect-timeout 1 --max-time 2 "http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}" >/dev/null 2>&1; then
  echo "Open WebUI still appears to be running on port ${OPEN_WEBUI_PORT}." >&2
  exit 1
fi

if [[ "${stopped_any}" -eq 1 ]]; then
  echo "Open WebUI stopped."
else
  echo "Open WebUI is not running."
fi
WRAPEOF

cat > "${BIN_DIR}/open-webui-status" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-__OPEN_WEBUI_HOST__}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-__OPEN_WEBUI_PORT__}"
PID_FILE="${INSTALL_ROOT}/open-webui-data/logs/open-webui.pid"

if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  echo "Open WebUI: running"
else
  echo "Open WebUI: stopped"
fi

echo "Open WebUI URL: http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}"
echo "Windows URL: http://localhost:${OPEN_WEBUI_PORT}"
echo "Open WebUI data: ${INSTALL_ROOT}/open-webui-data"
echo "Open WebUI log: ${INSTALL_ROOT}/open-webui-data/logs/open-webui.log"
echo "Open WebUI MCP setup note: ${INSTALL_ROOT}/mcp/config/open-webui-mcp-servers.md"
WRAPEOF

cat > "${BIN_DIR}/brain-status" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
OPEN_WEBUI_HOST="${NYMPHS_BRAIN_OPEN_WEBUI_HOST:-__OPEN_WEBUI_HOST__}"
OPEN_WEBUI_PORT="${NYMPHS_BRAIN_OPEN_WEBUI_PORT:-__OPEN_WEBUI_PORT__}"
MCP_HOST="${NYMPHS_BRAIN_MCP_HOST:-${NYMPHS_BRAIN_MCPO_HOST:-__MCP_HOST__}}"
MCP_PORT="${NYMPHS_BRAIN_MCP_PORT:-${NYMPHS_BRAIN_MCPO_PORT:-__MCP_PORT__}}"
CURL_CHECK_ARGS=(--silent --show-error --fail --connect-timeout 2 --max-time 5)

echo "Brain install: $([[ -x "${SCRIPT_DIR}/lms-start" ]] && echo installed || echo missing)"
if [[ -f "${INSTALL_ROOT}/secrets/llm-wrapper.env" ]]; then
  REMOTE_MODEL="$(sed -n 's/^REMOTE_LLM_MODEL=//p' "${INSTALL_ROOT}/secrets/llm-wrapper.env" | tail -1)"
else
  REMOTE_MODEL=""
fi

# Check llama-server on port 8000
if curl "${CURL_CHECK_ARGS[@]}" "http://127.0.0.1:8000/v1/models" >/tmp/nymphs-brain-models.json 2>/dev/null; then
  echo "llama-server: running on port 8000"
  MODEL_OUTPUT="$("${INSTALL_ROOT}/venv/bin/python3" -c "import json; from pathlib import Path; data=json.loads(Path('/tmp/nymphs-brain-models.json').read_text(encoding='utf-8')); models=data.get('data', []); loaded=[item.get('id') for item in models if isinstance(item, dict) and item.get('id')]; print(', '.join(loaded) if loaded else 'none reported')" 2>/dev/null || echo unknown)"
  echo "Model loaded: ${MODEL_OUTPUT}"
else
  echo "llama-server: stopped"
  MODEL_NAME="$(sed -n 's/^MODEL_KEY="\([^"]*\)".*/\1/p' "${SCRIPT_DIR}/lms-start" | head -n 1)"
  echo "Model configured: ${MODEL_NAME:-none}"
fi
echo "Remote llm-wrapper model: ${REMOTE_MODEL:-deepseek/deepseek-chat}"

if curl "${CURL_CHECK_ARGS[@]}" "http://${MCP_HOST}:${MCP_PORT}/status" >/dev/null 2>&1 ||
   curl "${CURL_CHECK_ARGS[@]}" "http://${MCP_HOST}:${MCP_PORT}/" >/dev/null 2>&1 ||
   ss -ltn 2>/dev/null | awk -v target=":${MCP_PORT}" 'index($4, target) { found=1 } END { exit(found ? 0 : 1) }'; then
  echo "MCP proxy: running"
else
  echo "MCP proxy: stopped"
fi

if curl "${CURL_CHECK_ARGS[@]}" "http://${OPEN_WEBUI_HOST}:${OPEN_WEBUI_PORT}" >/dev/null 2>&1; then
  echo "Open WebUI: running"
else
  echo "Open WebUI: stopped"
fi
WRAPEOF

cat > "${BIN_DIR}/nymph-chat" <<'WRAPEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$(dirname "${SCRIPT_DIR}")"
export PATH="${INSTALL_ROOT}/bin:${INSTALL_ROOT}/local-tools/bin:${INSTALL_ROOT}/local-tools/node/bin:${INSTALL_ROOT}/npm-global/bin:${PATH}"
"${INSTALL_ROOT}/venv/bin/python3" "${INSTALL_ROOT}/nymph-agent.py"
WRAPEOF

cat > "${BIN_DIR}/brain-env" <<WRAPEOF
#!/usr/bin/env bash
export NYMPHS_BRAIN_ROOT="${INSTALL_ROOT}"
export NYMPHS_BRAIN_OPEN_WEBUI_URL="http://localhost:${OPEN_WEBUI_PORT}"
export NYMPHS_BRAIN_MCP_URL="http://localhost:${MCP_PORT}"
export PATH="${BIN_DIR}:${LOCAL_BIN_DIR}:${LOCAL_NODE_DIR}/bin:${NPM_GLOBAL}/bin:\${PATH}"
WRAPEOF

cat > "${SCRIPTS_DIR}/monitor_query.sh" <<'WRAPEOF'
#!/usr/bin/env bash
# Monitor helper script - called from Windows via wsl.exe
# Usage: monitor_query.sh <query>

set -euo pipefail

LOG_FILE="$HOME/Nymphs-Brain/logs/lms.log"
LMS_START="$HOME/Nymphs-Brain/bin/lms-start"

case "${1:-}" in
    pid)
        ss -ltnp 2>/dev/null | awk '
            index($4, ":8000") && match($0, /pid=[0-9]+/) {
                print substr($0, RSTART + 4, RLENGTH - 4)
                exit
            }'
        ;;

    model)
        model=$(grep 'general.name str' "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/.*= //' || true)
        if [ -n "$model" ]; then
            echo "$model"
        else
            echo "-"
        fi
        ;;

    context)
        ctx=$(grep -oP 'CONTEXT_LENGTH="?\K[0-9]+' "$LMS_START" 2>/dev/null | head -1 || true)
        if [ -n "$ctx" ]; then
            echo "$ctx" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
        else
            echo "-"
        fi
        ;;

    gpu-vram)
        read -r used total < <(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr ',' ' ') || true
        used=$(echo "${used:-}" | tr -d ' ')
        total=$(echo "${total:-}" | tr -d ' ')
        if [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$total" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            awk "BEGIN {printf \"%.0f GB/%.0f GB\\n\", $used/1024, $total/1024}"
        else
            echo "-"
        fi
        ;;

    gpu-temp)
        temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)
        if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "${temp}C"
        else
            echo "-"
        fi
        ;;

    tps)
        tps=$(grep 'eval time' "$LOG_FILE" 2>/dev/null | grep -v 'prompt eval time' | tail -1 \
            | grep -oP '[0-9.]+\s*tokens per second' | grep -oP '^[0-9.]+' || true)
        if [ -n "$tps" ]; then
            echo "$tps"
        else
            echo "Waiting"
        fi
        ;;

    *)
        echo "Usage: monitor_query.sh {pid|model|context|gpu-vram|gpu-temp|tps}"
        exit 1
        ;;
esac
WRAPEOF

# Robust template replacement that handles CRLF line endings (from Windows installer)
# This awk-based approach is more reliable than sed for cross-platform scenarios

replace_template_vars() {
    local file="$1"
    awk -v MODEL_ID="${MODEL_ID}" \
        -v CONTEXT_LENGTH="${CONTEXT_LENGTH}" \
        -v MCP_HOST="${MCP_HOST}" \
        -v MCP_PORT="${MCP_PORT}" \
        -v MCPO_OPENAPI_PORT="${MCPO_OPENAPI_PORT}" \
        -v OPEN_WEBUI_HOST="${OPEN_WEBUI_HOST}" \
        -v OPEN_WEBUI_PORT="${OPEN_WEBUI_PORT}" '
    BEGIN { RS=ORS="\n" }
    {
        # Strip CRLF to handle Windows line endings
        gsub(/\r$/, "")
        # Replace template placeholders
        gsub(/__MODEL_ID__/, MODEL_ID)
        gsub(/__CONTEXT_LENGTH__/, CONTEXT_LENGTH)
        gsub(/__MCP_HOST__/, MCP_HOST)
        gsub(/__MCP_PORT__/, MCP_PORT)
        gsub(/__MCPO_OPENAPI_PORT__/, MCPO_OPENAPI_PORT)
        gsub(/__OPEN_WEBUI_HOST__/, OPEN_WEBUI_HOST)
        gsub(/__OPEN_WEBUI_PORT__/, OPEN_WEBUI_PORT)
        print
    }
    ' "$file" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
}

# Apply template variable replacements to all generated scripts
replace_template_vars "${BIN_DIR}/lms-start"
replace_template_vars "${BIN_DIR}/lms-stop"
replace_template_vars "${BIN_DIR}/mcp-start"
replace_template_vars "${BIN_DIR}/mcp-stop"
replace_template_vars "${BIN_DIR}/mcp-status"
replace_template_vars "${BIN_DIR}/open-webui-start"
replace_template_vars "${BIN_DIR}/open-webui-stop"
replace_template_vars "${BIN_DIR}/open-webui-status"
replace_template_vars "${BIN_DIR}/brain-status"

# Also update nymph-agent.py with the same robust replacement
awk -v MODEL_ID="${MODEL_ID}" '
BEGIN { RS=ORS="\n" }
{
    gsub(/\r$/, "")
    gsub(/__MODEL_ID__/, MODEL_ID)
    print
}
' "${INSTALL_ROOT}/nymph-agent.py" > "${INSTALL_ROOT}/nymph-agent.py.tmp" && mv -f "${INSTALL_ROOT}/nymph-agent.py.tmp" "${INSTALL_ROOT}/nymph-agent.py"
chmod +x \
  "${BIN_DIR}/lms-start" \
  "${BIN_DIR}/lms-model" \
  "${BIN_DIR}/lms-stop" \
  "${BIN_DIR}/lms-update" \
  "${BIN_DIR}/lms-status" \
  "${BIN_DIR}/mcp-start" \
  "${BIN_DIR}/mcp-stop" \
  "${BIN_DIR}/mcp-status" \
  "${BIN_DIR}/open-webui-start" \
  "${BIN_DIR}/open-webui-stop" \
  "${BIN_DIR}/open-webui-status" \
  "${BIN_DIR}/brain-status" \
  "${BIN_DIR}/nymph-chat" \
  "${BIN_DIR}/brain-env" \
  "${SCRIPTS_DIR}/monitor_query.sh"

cat > "${INSTALL_ROOT}/install-summary.txt" <<EOF
Nymphs-Brain experimental local LLM stack (hybrid architecture)
Install root: ${INSTALL_ROOT}
Model: ${MODEL_ID:-none}
Quantization: ${QUANTIZATION}
Context length: ${CONTEXT_LENGTH}
Model download during install: ${DOWNLOAD_MODEL}

Architecture:
- LM Studio: Used for model download/management only (lms-model, lms commands)
- llama-server: Serves LLM on port 8000 (CUDA accelerated via llama.cpp)

Commands:
  LLM Server:
  - Start server:   ${BIN_DIR}/lms-start
  - Stop server:    ${BIN_DIR}/lms-stop
  - Check status:   ${BIN_DIR}/lms-status
  - Manage models:  ${BIN_DIR}/lms-model (uses LM Studio CLI for downloads)

  Chat & UI:
  - Run chat wrapper: ${BIN_DIR}/nymph-chat
  - Start Open WebUI: ${BIN_DIR}/open-webui-start
  - Stop Open WebUI:  ${BIN_DIR}/open-webui-stop
  - Check Open WebUI: ${BIN_DIR}/open-webui-status

  MCP Gateway:
  - Start MCP:    ${BIN_DIR}/mcp-start
  - Stop MCP:     ${BIN_DIR}/mcp-stop
  - Check MCP:    ${BIN_DIR}/mcp-status

  Overall Status:
  - ${BIN_DIR}/brain-status

API Endpoints:
- llama-server API: http://localhost:8000/v1/chat/completions
- Open WebUI:       http://localhost:${OPEN_WEBUI_PORT}
- MCP gateway:      http://localhost:${MCP_PORT}

Streamable HTTP MCP endpoints:
- http://localhost:${MCP_PORT}/servers/filesystem/mcp
- http://localhost:${MCP_PORT}/servers/memory/mcp
- http://localhost:${MCP_PORT}/servers/web-forager/mcp
EOF

echo "============================================================"
echo "Nymphs-Brain setup complete (hybrid LM Studio + llama-server)"
echo "============================================================"
echo ""
echo "Architecture summary:"
echo "  - Use 'lms-model' to download/manage models via LM Studio"
echo "  - Use 'lms-start' to launch llama-server (port 8000) with CUDA"
echo "  - llama-server provides OpenAI-compatible API on port 8000"
echo ""
echo "Quick start:"
echo "  ${BIN_DIR}/lms-model   # Download/configure a model first"
echo "  ${BIN_DIR}/lms-start   # Start the LLM server (port 8000)"
echo "  ${BIN_DIR}/mcp-start   # Start MCP gateway"
echo "  ${BIN_DIR}/open-webui-start  # Start Open WebUI"
