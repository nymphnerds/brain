# Brain Module Migration Notes

Brain is different from Z-Image and TRELLIS.2.

The live install folder:

```text
/home/nymph/Nymphs-Brain
```

is not a source repo. It is a generated runtime folder containing:

- wrapper scripts
- Python virtual environments
- local Node/npm tools
- LM Studio CLI state
- built `llama-server` binaries and shared libraries
- Open WebUI databases and logs
- MCP config/data/logs
- model files
- secrets

Those should not be copied into git.

## Module Identity

```text
id: brain
name: Brain
short name: BR
repo: github.com/nymphnerds/brain
install path: ~/Nymphs-Brain
```

## Source Of Truth

The clean module repo owns the installer and helper source:

```text
scripts/install_brain.sh
scripts/remote_llm_mcp/
```

The installer came from:

```text
NymphsCore/Manager/scripts/install_nymphs_brain.sh
```

The remote LLM MCP bridge came from:

```text
NymphsCore/Manager/scripts/remote_llm_mcp/
```

## Service Shape

Brain manages several services:

```text
llama-server: 8000
Open WebUI:   8081
MCP gateway:  8100
mcpo bridge:  8099
```

The Manager page should stay native and module-owned through `nymph.json`.
Open WebUI uses the WORBI-style `local_url` path. Manage Models keeps the
interactive `lms-model` terminal flow.

## What Stays Out Of Git

- `venv`
- `mcp-venv`
- `open-webui-venv`
- `open-webui-data`
- `models`
- `local-tools`
- `lmstudio`
- `npm-global`
- `mcp/data`
- `mcp/logs`
- `secrets`
- generated backups

## Migration Rule

Brain should be migrated as an installer module first. Do not try to make the live runtime folder itself into a repo.
