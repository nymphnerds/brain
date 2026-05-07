#!/bin/bash
set -euo pipefail

#############################################################################
# uninstall-llm-wrapper.sh
# 
# Removes Cached LLM MCP Server from Nymphs-Brain MCP proxy configuration
#
# Usage: Copy this script to a target PC and run: ./uninstall-llm-wrapper.sh
#############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}"
    echo "=================================================="
    echo "  LLM Wrapper MCP Server Uninstaller"
    echo "  for Nymphs-Brain MCP Proxy"
    echo "=================================================="
    echo -e "${NC}"
    echo ""
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

# Remove prompt cache directory
remove_cache() {
    echo ""
    print_info "Removing prompt cache..."
    
    CACHE_DIR="$NYMPHS_DIR/mcp/data/llm_cache"
    
    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        print_success "Cache directory removed: $CACHE_DIR"
    else
        print_info "No cache directory found, skipping..."
    fi
}

# Restore original mcp-start script
restore_mcp_start() {
    echo ""
    print_info "Restoring MCP proxy configuration..."
    
    MCP_START="$NYMPHS_DIR/bin/mcp-start"
    ORIGINAL_MCP_START="${MCP_START}.original"
    
    if [[ -f "$ORIGINAL_MCP_START" ]]; then
        cp "$ORIGINAL_MCP_START" "$MCP_START"
        print_success "Restored original mcp-start from backup"
        
        # Optionally remove the backup file
        read -rp "  Remove backup file ($ORIGINAL_MCP_START)? (Y/n): " remove_backup
        if [[ "${remove_backup,,}" == "y" ]] || [[ "${remove_backup,,}" == "yes" ]] || [[ -z "$remove_backup" ]]; then
            rm -f "$ORIGINAL_MCP_START"
            print_success "Backup file removed"
        fi
    else
        # If no backup, try to remove llm-wrapper section from current config
        print_warning "No backup found. Attempting to remove llm-wrapper from current config..."
        
        python3 <<PYTHON
import re

with open("$MCP_START", 'r') as f:
    content = f.read()

# Remove existing llm-wrapper block
pattern = r',?\s*"llm-wrapper"\s*:\s*\{[^}]+\}'
content = re.sub(pattern, '', content, flags=re.DOTALL)

with open("$MCP_START", 'w') as f:
    f.write(content)
    
print("Removed llm-wrapper configuration from mcp-start")
PYTHON
        
        print_success "Removed llm-wrapper from mcp-start"
    fi
}

# Remove Cline MCP settings entry
remove_cline_settings() {
    echo ""
    print_info "Updating Cline MCP settings..."
    
    # Check multiple possible locations for Cline MCP settings
    CLINE_LOCATIONS=(
        "$HOME/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
        "$NYMPHS_DIR/mcp/config/cline-mcp-settings.json"
    )
    
    updated_count=0
    
    for CLINE_SETTINGS in "${CLINE_LOCATIONS[@]}"; do
        if [[ -f "$CLINE_SETTINGS" ]]; then
            # Use Python to properly update the JSON
            result=$(python3 <<PYTHON
import json

settings_file = "$CLINE_SETTINGS"

with open(settings_file, 'r') as f:
    settings = json.load(f)

if "mcpServers" in settings and "llm-wrapper" in settings["mcpServers"]:
    del settings["mcpServers"]["llm-wrapper"]
    with open(settings_file, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print("removed")
else:
    print("not_found")
PYTHON
)
            if [[ "$result" == "removed" ]]; then
                print_info "  Updated: $CLINE_SETTINGS"
                ((updated_count++)) || true
            fi
        fi
    done
    
    if [[ $updated_count -gt 0 ]]; then
        print_success "Updated $updated_count Cline settings file(s)"
    else
        print_info "No Cline settings files needed updating"
    fi
}

# Remove secrets file
remove_secrets() {
    echo ""
    SECRETS_FILE="$NYMPHS_DIR/secrets/llm-wrapper.env"
    
    if [[ -f "$SECRETS_FILE" ]]; then
        rm -f "$SECRETS_FILE"
        print_success "Removed API key from $SECRETS_FILE"
    else
        print_info "No secrets file found, skipping..."
    fi
}

# Restart MCP proxy
restart_proxy() {
    echo ""
    print_info "Restarting MCP proxy..."
    
    MCP_STOP="$NYMPHS_DIR/bin/mcp-stop"
    MCP_START_CMD="$NYMPHS_DIR/bin/mcp-start"
    
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
    else
        print_error "mcp-start command not found or not executable"
    fi
}

# Display completion summary
show_summary() {
    echo ""
    echo -e "${GREEN}"
    echo "=================================================="
    echo "  Uninstallation Complete!"
    echo "=================================================="
    echo -e "${NC}"
    echo ""
    echo "The llm-wrapper MCP server has been removed."
    echo ""
    echo "To reinstall at any time, run: install-llm-wrapper.sh"
    echo ""
}

# Main uninstallation flow
main() {
    print_header
    
    echo "This will remove the llm-wrapper MCP server from your Nymphs-Brain setup."
    echo ""
    read -rp "Continue? (y/N): " confirm
    
    if [[ "${confirm,,}" != "y" ]] && [[ "${confirm,,}" != "yes" ]]; then
        print_info "Uninstallation cancelled."
        exit 0
    fi
    
    detect_nymphs_brain
    remove_cache
    restore_mcp_start
    remove_cline_settings
    remove_secrets
    restart_proxy
    show_summary
}

main "$@"