#!/usr/bin/env python3
"""
Patch script for llm-wrapper-mcp-server to fix MCP protocol compliance.

The original package returns tools as a dictionary in tools/list responses,
but the MCP spec requires a list of tool objects with "name" field included.

Usage: ./patch-llm-wrapper.py /path/to/venv
"""
import sys
import os
from pathlib import Path


def patch_llm_mcp_wrapper(venv_path: str) -> None:
    """Apply the MCP protocol fix to llm_mcp_wrapper.py."""
    
    venv_path = Path(venv_path)
    wrapper_file = venv_path / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages" / "llm_wrapper_mcp_server" / "llm_mcp_wrapper.py"
    
    if not wrapper_file.exists():
        print(f"Error: llm_mcp_wrapper.py not found at {wrapper_file}")
        print("Make sure the venv path is correct and llm-wrapper-mcp-server is installed.")
        sys.exit(1)
    
    # Read the original file
    with open(wrapper_file, 'r') as f:
        content = f.read()
    
    # Check if already patched
    if 'tools_list = [' in content and '**tool_def' in content:
        print("Already patched - no action needed.")
        return
    
    # Create backup
    backup_file = wrapper_file.with_suffix('.py.backup')
    with open(backup_file, 'w') as f:
        f.write(content)
    print(f"Created backup: {backup_file}")
    
    # Apply the patch - find and replace the tools/list handler
    old_code = '''            elif method == "tools/list":
                logger.debug("Handling tools/list request.", extra={'request_id': request_id})
                self.send_response({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "tools": self.tools
                    }
                })'''
    
    new_code = '''            elif method == "tools/list":
                logger.debug("Handling tools/list request.", extra={'request_id': request_id})
                # Convert dict format to MCP list format: [{"name": "...", "description": "...", "inputSchema": {...}}]
                tools_list = [
                    {
                        "name": name,
                        **tool_def
                    }
                    for name, tool_def in self.tools.items()
                ]
                self.send_response({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "tools": tools_list
                    }
                })'''
    
    if old_code not in content:
        print("Warning: Could not find the exact code to patch. The file may have been modified.")
        print("Please review the backup and apply patches manually if needed.")
        sys.exit(1)
    
    content = content.replace(old_code, new_code)
    
    # Write the patched file
    with open(wrapper_file, 'w') as f:
        f.write(content)
    
    print(f"Successfully patched {wrapper_file}")


def main():
    if len(sys.argv) < 2:
        # Try to find Nymphs-Brain MCP venv in common locations
        common_paths = [
            Path.home() / "Nymphs-Brain" / "mcp-venv",
            Path.cwd().parent / "Nymphs-Brain" / "mcp-venv",
            Path.cwd() / "Nymphs-Brain" / "mcp-venv",
            Path("/home/rauty/Nymphs-Brain/mcp-venv"),
        ]
        
        for path in common_paths:
            if (path / "bin" / "python").exists():
                print(f"Auto-detected venv at: {path}")
                patch_llm_mcp_wrapper(str(path))
                return
        
        print("Usage: patch-llm-wrapper.py /path/to/venv")
        print("\nCommon locations:")
        for path in common_paths:
            print(f"  {path}")
        sys.exit(1)
    
    venv_path = sys.argv[1]
    patch_llm_mcp_wrapper(venv_path)


if __name__ == "__main__":
    main()