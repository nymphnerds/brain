#!/bin/bash
set -euo pipefail

#############################################################################
# install-llm-wrapper.sh
# 
# Interactive installer for Cached LLM MCP Server on Nymphs-Brain systems
# Enables Cline's local LLM to delegate tasks to powerful cloud models via OpenRouter
# Features:
#   - Prompt caching (SQLite) to avoid repeated API calls for identical prompts
#   - One-shot response framing to prevent multi-turn loops between local/remote LLMs
#   - 120s timeout for complex prompts on free-tier models
# Supports both native Linux and WSL (Windows Subsystem for Linux) environments
#
# Usage: 
#   ./install-llm-wrapper.sh          # Normal installation
#   ./install-llm-wrapper.sh --dry-run # Preview changes without applying
#############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# WSL Detection Function
# ============================================================================
is_wsl() {
    # Check if running in Windows Subsystem for Linux by looking for "microsoft" 
    # in the kernel version string (case-insensitive)
    if grep -qi microsoft /proc/version 2>/dev/null; then
        return 0  # True - we are in WSL
    else
        return 1  # False - native Linux
    fi
}

# Detect environment at script start
IS_WSL=false
if is_wsl; then
    IS_WSL=true
fi

# Dry-run mode flag
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Pre-configured model options with descriptions
declare -A MODELS=(
    ["1"]="anthropic/claude-3.5-sonnet:best reasoning and coding"
    ["2"]="openai/gpt-4o:excellent all-rounder"
    ["3"]="google/gemini-flash-1.5:fast and cost-effective"
    ["4"]="deepseek/deepseek-chat:great for code tasks"
    ["5"]="nvidia/nemotron-3-super-120b-a12b:free tier available"
    ["6"]="anthropic/claude-3-haiku:fast responses, cheaper"
    ["7"]="openai/gpt-4o-mini:lightweight GPT-4"
    ["9"]="custom"
)

print_header() {
    echo -e "${BLUE}"
    echo "=================================================="
    echo "  LLM Wrapper MCP Server Installer"
    echo "  for Nymphs-Brain MCP Proxy"
    echo "=================================================="
    echo -e "${NC}"
    
    # Display environment detection info
    if [[ "$IS_WSL" == "true" ]]; then
        echo -e "${YELLOW}  Detected: Windows Subsystem for Linux (WSL)${NC}"
        echo -e "${YELLOW}  Note: MCP proxy will bind to 0.0.0.0 for Windows access${NC}"
        echo ""
    else
        echo -e "${GREEN}  Detected: Native Linux${NC}"
        echo ""
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}  *** DRY-RUN MODE - No changes will be made ***${NC}"
        echo ""
    fi
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ Error: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ Warning: $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Detect Nymphs-Brain installation directory
detect_nymphs_brain() {
    print_info "Detecting Nymphs-Brain installation..."
    
    NYMPHS_DIR=""
    
    # Check common locations
    for path in \
        "$(pwd)" \
        "../Nymphs-Brain" \
        "./Nymphs-Brain" \
        "/home/*/Nymphs-Brain" \
        "~/Nymphs-Brain" \
        "$HOME/Nymphs-Brain"
    do
        if [[ -d "$path" ]] && [[ -f "$path/bin/mcp-start" ]]; then
            NYMPHS_DIR="$(cd "$path" && pwd)"
            break
        fi
    done
    
    # If not found, check parent directories from current location
    if [[ -z "$NYMPHS_DIR" ]]; then
        local current_dir="$PWD"
        for i in {1..5}; do
            if [[ -f "${current_dir}/bin/mcp-start" ]] && [[ -d "${current_dir}/mcp-venv" ]]; then
                NYMPHS_DIR="$current_dir"
                break
            fi
            current_dir="$(dirname "$current_dir")"
        done
    fi
    
    if [[ -n "$NYMPHS_DIR" ]]; then
        print_success "Found Nymphs-Brain at: $NYMPHS_DIR"
    else
        # Fall back to assuming the script is being run from or near Nymphs-Brain
        if [[ -f "Nymphs-Brain/bin/mcp-start" ]]; then
            NYMPHS_DIR="$(cd Nymphs-Brain && pwd)"
            print_success "Found Nymphs-Brain at: $NYMPHS_DIR"
        fi
    fi
    
    if [[ -z "$NYMPHS_DIR" ]]; then
        print_error "Could not automatically detect Nymphs-Brain installation."
        echo ""
        print_info "Please enter the path to your Nymphs-Brain directory:"
        read -rp "  Path: " NYMPHS_DIR
        NYMPHS_DIR="$(cd "$NYMPHS_DIR" 2>/dev/null && pwd)" || {
            print_error "Invalid path provided."
            exit 1
        }
    fi
    
    # Verify required components exist
    if [[ ! -d "$NYMPHS_DIR/mcp-venv" ]]; then
        print_error "MCP venv not found at $NYMPHS_DIR/mcp-venv"
        exit 1
    fi
    if [[ ! -f "$NYMPHS_DIR/bin/mcp-start" ]]; then
        print_error "mcp-start script not found at $NYMPHS_DIR/bin/mcp-start"
        exit 1
    fi
    
    print_success "Verified Nymphs-Brain structure"
}

# Get OpenRouter API key from user
get_api_key() {
    echo ""
    print_info "OpenRouter API Configuration"
    echo "  This installer will connect your local LLM to powerful cloud models."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  (In dry-run mode, no API key is needed)"
    fi
    echo ""
    
    SECRETS_DIR="$NYMPHS_DIR/secrets"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY-RUN] Would create: $SECRETS_DIR/llm-wrapper.env"
        print_info "[DRY-RUN] Would store OPENROUTER_API_KEY (provided by user during real install)"
        API_KEY="sk-or-xxxxxxxxxxxxxxxxxx" # Placeholder for dry-run
    else
        while true; do
            read -rp "  Enter your OpenRouter API key (sk-or-...): " API_KEY
            
            if [[ -z "$API_KEY" ]]; then
                print_warning "API key cannot be empty. Please try again."
                continue
            fi
            
            # Validate format (basic check)
            if [[ ! "$API_KEY" =~ ^sk-or- ]]; then
                print_warning "Warning: API key doesn't match expected OpenRouter format (sk-or-...)"
                read -rp "  Continue anyway? (y/N): " confirm
                if [[ "${confirm,,}" != "y" ]] && [[ "${confirm,,}" != "yes" ]]; then
                    continue
                fi
            fi
            
            break
        done
        
        # Store API key in secrets directory
        mkdir -p "$SECRETS_DIR"
        
        cat > "$SECRETS_DIR/llm-wrapper.env" <<EOF
# LLM Wrapper MCP Server Configuration
# Generated by install-llm-wrapper.sh on $(date)

# Your OpenRouter API key
OPENROUTER_API_KEY=$API_KEY
EOF
        
        chmod 600 "$SECRETS_DIR/llm-wrapper.env"
        print_success "API key saved to $SECRETS_DIR/llm-wrapper.env"
    fi
}

# Select model from menu
select_model() {
    echo ""
    print_info "Select Default Model for Delegated Tasks"
    echo ""
    echo "  When your local LLM delegates a task, it will use this model by default."
    echo ""
    
    # Display model options
    for key in $(echo "${!MODELS[@]}" | tr ' ' '\n' | sort); do
        local value="${MODELS[$key]}"
        local model_name="${value%%:*}"
        local description="${value#*:}"
        printf "  %s) %-35s %s\n" "$key" "$model_name" "$description"
    done
    echo ""
    
    while true; do
        read -rp "  Select option (1-9): " choice
        
        if [[ "$choice" == "9" ]]; then
            read -rp "  Enter custom model name (e.g., mistralai/mistral-7b-instruct): " SELECTED_MODEL
            if [[ -n "$SELECTED_MODEL" ]]; then
                break
            fi
            print_warning "Custom model name cannot be empty."
        elif [[ -n "${MODELS[$choice]+isset}" ]]; then
            SELECTED_MODEL="${MODELS[$choice]%%:*}"
            break
        else
            print_warning "Invalid option. Please enter 1-9."
        fi
    done
    
    print_success "Selected model: $SELECTED_MODEL"
}

# Verify cached LLM MCP server script and create cache directory
install_cached_server() {
    echo ""
    
    CACHED_SERVER="${SCRIPT_DIR}/cached_llm_mcp_server.py"
    
    if [[ ! -f "$CACHED_SERVER" ]]; then
        print_error "Cached LLM MCP server script not found at $CACHED_SERVER"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY-RUN] Would verify: $CACHED_SERVER"
        print_info "[DRY-RUN] Would create cache directory: $NYMPHS_DIR/mcp/data/llm_cache/"
    else
        print_info "Verifying Cached LLM MCP Server script..."
        python3 -c "import py_compile; py_compile.compile('$CACHED_SERVER', doraise=True)"
        if [[ $? -eq 0 ]]; then
            print_success "Cached LLM MCP Server script is valid"
        else
            print_error "Cached LLM MCP Server script has syntax errors"
            exit 1
        fi
        
        # Create cache directory
        mkdir -p "$NYMPHS_DIR/mcp/data/llm_cache"
        print_success "Cache directory created at $NYMPHS_DIR/mcp/data/llm_cache/"
    fi
}

# Create or update the mcp-start script with llm-wrapper config
update_mcp_start() {
    echo ""
    
    MCP_START="$NYMPHS_DIR/bin/mcp-start"
    ORIGINAL_MCP_START="${MCP_START}.original"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY-RUN] MCP Proxy Configuration Preview"
        echo ""
        echo "  File: $MCP_START"
        echo ""
        echo "  Would add the following llm-wrapper configuration after context7:"
        cat <<EOF

    "llm-wrapper": {
      "command": "bash",
      "args": ["-c", "export \$(grep -v '^#' \${SECRET_DIR}/llm-wrapper.env | xargs) && \${MCP_VENV_DIR}/bin/python \${RESOLVED_INSTALL_ROOT}/../remote_llm_mcp/cached_llm_mcp_server.py --model $SELECTED_MODEL --timeout 120 --cache-ttl 3600 --cache-dir \${RESOLVED_INSTALL_ROOT}/mcp/data/llm_cache"],
      "env": {
        "SECRET_DIR": "\${SECRET_DIR}",
        "LLM_API_BASE_URL": "https://openrouter.ai/api/v1"
      }
    }
EOF
        echo ""
        
        if [[ ! -f "$ORIGINAL_MCP_START" ]]; then
            print_info "[DRY-RUN] Would create backup: $ORIGINAL_MCP_START"
        fi
    else
        print_info "Updating MCP proxy configuration..."
        
        # Create backup if it doesn't exist
        if [[ ! -f "$ORIGINAL_MCP_START" ]]; then
            cp "$MCP_START" "$ORIGINAL_MCP_START"
            print_info "Created backup of original mcp-start at $ORIGINAL_MCP_START"
        fi
        
        # Check if llm-wrapper is already configured
        if grep -q '"llm-wrapper"' "$MCP_START"; then
            print_warning "llm-wrapper already exists in mcp-start config"
            read -rp "  Overwrite existing configuration? (y/N): " overwrite
            if [[ "${overwrite,,}" != "y" ]] && [[ "${overwrite,,}" != "yes" ]]; then
                print_info "Skipping configuration update."
                return
            fi
        fi
        
        # Add llm-wrapper configuration using line-based insertion (more reliable than regex)
        python3 <<PYTHON
import re

with open("$MCP_START", 'r') as f:
    lines = f.readlines()

# Find the line with context7's closing pattern and insert after it
llm_wrapper_config = '''    "llm-wrapper": {
      "command": "bash",
      "args": ["-c", "export \$(grep -v '^#' \${SECRET_DIR}/llm-wrapper.env | xargs) && \${MCP_VENV_DIR}/bin/python \${RESOLVED_INSTALL_ROOT}/../remote_llm_mcp/cached_llm_mcp_server.py --model $SELECTED_MODEL --timeout 120 --cache-ttl 3600 --cache-dir \${RESOLVED_INSTALL_ROOT}/mcp/data/llm_cache"],
      "env": {
        "SECRET_DIR": "\${SECRET_DIR}",
        "LLM_API_BASE_URL": "https://openrouter.ai/api/v1"
      }
    }
'''

output_lines = []
inserted = False

for i, line in enumerate(lines):
    output_lines.append(line)
    # Look for the closing of context7 block - the line with just "}" after the args array closes
    if '"context7"' in str(lines[max(0,i-5):i+1]) and line.strip() == '}' and not inserted:
        # Check if next non-empty line is also a closing brace (meaning we're at mcpServers close)
        j = i + 1
        while j < len(lines) and lines[j].strip() == '':
            j += 1
        if j < len(lines) and lines[j].strip() == '}':
            # This is the context7 closing brace, insert after it
            output_lines.append(',\n')
            output_lines.append(llm_wrapper_config)
            inserted = True

if not inserted:
    print("Warning: Could not find insertion point for llm-wrapper config")
    exit(1)

with open("$MCP_START", 'w') as f:
    f.writelines(output_lines)
    
print("llm-wrapper configuration added successfully")
PYTHON
        
        if [[ $? -eq 0 ]]; then
            print_success "Updated $MCP_START with llm-wrapper configuration"
        else
            print_error "Failed to update mcp-start config, restoring backup..."
            cp "$ORIGINAL_MCP_START" "$MCP_START"
            exit 1
        fi
    fi
}

# Update Cline MCP settings
update_cline_settings() {
    echo ""
    
    # Check multiple possible locations for Cline MCP settings
    CLINE_SETTINGS=""
    CLINE_LOCATIONS=(
        "$HOME/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
        "$NYMPHS_DIR/mcp/config/cline-mcp-settings.json"
    )
    
    for loc in "${CLINE_LOCATIONS[@]}"; do
        if [[ -f "$loc" ]]; then
            CLINE_SETTINGS="$loc"
            break
        fi
    done
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY-RUN] Cline MCP Settings Preview"
        echo ""
        
        for loc in "${CLINE_LOCATIONS[@]}"; do
            if [[ -f "$loc" ]]; then
                echo "  Found: $loc"
            fi
        done
        
        if [[ -z "$CLINE_SETTINGS" ]]; then
            echo "  Will create at: ${CLINE_LOCATIONS[1]}"
        fi
        
        echo ""
        echo "  Would add the following llm-wrapper server configuration:"
        cat <<EOF
{
  "mcpServers": {
    ...existing servers...,
    "llm-wrapper": {
      "url": "http://127.0.0.1:8100/servers/llm-wrapper/mcp",
      "type": "streamableHttp",
      "disabled": false,
      "timeout": 60
    }
  }
}
EOF
        echo ""
    else
        print_info "Updating Cline MCP settings..."
        
        if [[ -z "$CLINE_SETTINGS" ]]; then
            # Use the Nymphs-Brain default location
            CLINE_SETTINGS="${CLINE_LOCATIONS[1]}"
            print_warning "Cline settings not found in expected locations"
            echo "  Creating at: $CLINE_SETTINGS"
            mkdir -p "$(dirname "$CLINE_SETTINGS")"
            cat > "$CLINE_SETTINGS" <<EOF
{
  "mcpServers": {}
}
EOF
        fi
        
        # Use Python to properly update the JSON
        python3 <<PYTHON
import json

settings_file = "$CLINE_SETTINGS"

with open(settings_file, 'r') as f:
    settings = json.load(f)

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

# Add or update llm-wrapper server
settings["mcpServers"]["llm-wrapper"] = {
    "url": "http://127.0.0.1:8100/servers/llm-wrapper/mcp",
    "type": "streamableHttp",
    "disabled": False,
    "timeout": 60
}

# Preserve existing servers and formatting
with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYTHON
        
        print_success "Updated Cline MCP settings at $CLINE_SETTINGS"
        
        # Also update Nymphs-Brain config if it's a different file
        NYMPHS_CLINE="$NYMPHS_DIR/mcp/config/cline-mcp-settings.json"
        if [[ "$CLINE_SETTINGS" != "$NYMPHS_CLINE" ]] && [[ -f "$NYMPHS_CLINE" ]]; then
            echo ""
            print_info "Also updating Nymphs-Brain config..."
            python3 <<PYTHON
import json

settings_file = "$NYMPHS_CLINE"

with open(settings_file, 'r') as f:
    settings = json.load(f)

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

settings["mcpServers"]["llm-wrapper"] = {
    "url": "http://127.0.0.1:8100/servers/llm-wrapper/mcp",
    "type": "streamableHttp",
    "disabled": False,
    "timeout": 60
}

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYTHON
            print_success "Updated $NYMPHS_CLINE"
        fi
    fi
}

# Restart MCP proxy
restart_proxy() {
    echo ""
    
    MCP_STOP="$NYMPHS_DIR/bin/mcp-stop"
    MCP_START_CMD="$NYMPHS_DIR/bin/mcp-start"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY-RUN] Would restart MCP proxy"
        echo ""
        echo "  Commands that would be executed:"
        echo "  1. $MCP_STOP   (stop current proxy)"
        echo "  2. sleep 2"
        echo "  3. $MCP_START_CMD   (start proxy with new config)"
        echo ""
    else
        print_info "Restarting MCP proxy..."
        
        if [[ -x "$MCP_STOP" ]]; then
            "$MCP_STOP" || true
            sleep 2
        fi
        
        if [[ -x "$MCP_START_CMD" ]]; then
            "$MCP_START_CMD"
            
            # Wait for proxy to be ready
            print_info "Waiting for MCP proxy to start..."
            for i in {1..30}; do
                if curl -fsS "http://127.0.0.1:8100/status" >/dev/null 2>&1; then
                    print_success "MCP proxy is running"
                    break
                fi
                sleep 1
            done
            
            # Verify llm-wrapper endpoint
            if curl -fsS "http://127.0.0.1:8100/servers/llm-wrapper/mcp" >/dev/null 2>&1; then
                print_success "llm-wrapper MCP server is accessible"
            else
                print_warning "Could not verify llm-wrapper endpoint immediately - check logs if issues occur"
            fi
        else
            print_error "mcp-start command not found or not executable"
            exit 1
        fi
    fi
}

# Display completion summary
show_summary() {
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}"
        echo "=================================================="
        echo "  Dry-Run Complete - No Changes Made"
        echo "=================================================="
        echo -e "${NC}"
        echo ""
        echo "Summary of what WOULD be configured:"
        echo ""
        echo "  • API Key:       Would be saved to $SECRETS_DIR/llm-wrapper.env"
        echo "  • Default Model: $SELECTED_MODEL"
        echo "  • MCP Endpoint:  http://127.0.0.1:8100/servers/llm-wrapper/mcp"
        echo ""
        echo "The llm_call tool would be available to your local LLM with this schema:"
        echo '  { name: "llm_call", arguments: { prompt: "string" } }'
        echo ""
        echo "To proceed with actual installation, run without --dry-run flag:"
        echo "  ./install-llm-wrapper.sh"
        echo ""
    else
        echo -e "${GREEN}"
        echo "=================================================="
        echo "  Installation Complete!"
        echo "=================================================="
        echo -e "${NC}"
        echo ""
        echo "Your local LLM in Cline can now delegate tasks to cloud models."
        echo ""
        echo "Configuration Summary:"
        echo "  • API Key:       $SECRETS_DIR/llm-wrapper.env"
        echo "  • Default Model: $SELECTED_MODEL"
        echo "  • MCP Endpoint:  http://127.0.0.1:8100/servers/llm-wrapper/mcp"
        echo "  • Prompt Cache:  $NYMPHS_DIR/mcp/data/llm_cache/prompt_cache.sqlite"
        echo "  • Cache TTL:     3600s (1 hour)"
        echo "  • Request Timeout: 120s"
        echo "  • One-Shot Mode: ON (prevents multi-turn loops with remote LLM)"
        echo ""
        echo "The llm_call tool is now available to your local LLM with this schema:"
        echo '  { name: "llm_call", arguments: { prompt: "string" } }'
        echo ""
        echo "Key features:"
        echo "  - Prompt caching: identical prompts return instantly from cache"
        echo "  - One-shot framing: the remote LLM connection closes after each response,"
        echo "    preventing the local and remote LLMs from getting into a conversation loop"
        echo "  - Use cache_stats to view cache hits/misses, cache_clear to reset"
        echo ""
        echo "Example usage in Cline chat:"
        echo '  "Use the llm_call tool to ask GPT-4o about [complex task]"'
        echo ""
        echo "To change the model or cache settings, edit: $NYMPHS_DIR/bin/mcp-start"
        echo "To uninstall, run: ${SCRIPT_DIR}/uninstall-llm-wrapper.sh"
        echo ""
    fi
}

# Configure MCP host based on environment
configure_mcp_host() {
    if [[ "$IS_WSL" == "true" ]]; then
        # In WSL, bind to 0.0.0.0 so Windows can access via localhost
        export NYMPHS_BRAIN_MCP_HOST="0.0.0.0"
        print_info "WSL detected: Setting MCP_HOST=0.0.0.0 for Windows access"
    else
        # Native Linux: use default 127.0.0.1 (more secure)
        export NYMPHS_BRAIN_MCP_HOST="127.0.0.1"
    fi
}

# Get the MCP endpoint URL based on environment
get_mcp_endpoint_url() {
    if [[ "$IS_WSL" == "true" ]]; then
        # In WSL, Windows can access via localhost due to automatic port forwarding
        echo "http://127.0.0.1:8100/servers/llm-wrapper/mcp"
    else
        echo "http://127.0.0.1:8100/servers/llm-wrapper/mcp"
    fi
}

# Main installation flow
main() {
    print_header
    
    # Configure MCP host before other operations
    configure_mcp_host
    
    detect_nymphs_brain
    get_api_key
    select_model
    install_cached_server
    update_mcp_start
    update_cline_settings
    restart_proxy
    show_summary
}

main "$@"
