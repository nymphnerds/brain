# Brain

Brain is the NymphsCore local assistant and orchestration stack packaged as an installable Nymph module.

It installs and manages:

- local `llama-server` on port `8000`
- LM Studio CLI for model download and model management
- Open WebUI on port `8081`
- MCP gateway on port `8100`
- mcpo OpenAPI bridge on port `8099`
- filesystem, memory, web-forager, context7, and remote LLM wrapper tool bridges

This repo is intentionally the clean installer/contract repo. It is not a dump of a live `~/Nymphs-Brain` runtime folder.

## Runtime Layout

Expected in-distro install path:

```text
~/Nymphs-Brain
```

Generated runtime folders include:

```text
~/Nymphs-Brain/bin
~/Nymphs-Brain/venv
~/Nymphs-Brain/mcp-venv
~/Nymphs-Brain/open-webui-venv
~/Nymphs-Brain/open-webui-data
~/Nymphs-Brain/models
~/Nymphs-Brain/local-tools
~/Nymphs-Brain/secrets
~/Nymphs-Brain/logs
```

Those folders are local runtime state and must not be committed to this repo.

## Manager Contract

The manager discovers this module through `nymph.json`.

Useful scripts:

```bash
scripts/install_brain.sh
scripts/brain_status.sh
scripts/brain_start.sh
scripts/brain_stop.sh
scripts/brain_webui.sh
scripts/brain_manage_models.sh
scripts/brain_apply_key.sh
scripts/brain_open.sh
scripts/brain_logs.sh
```

Brain uses native Manager module actions. Open WebUI is exposed through the
WORBI-style `local_url` path, and Manage Models keeps the installed interactive
`lms-model` terminal flow.

## Default Local URLs

```text
llama-server API: http://localhost:8000/v1/chat/completions
Open WebUI:       http://localhost:8081
MCP gateway:      http://localhost:8100
mcpo OpenAPI:     http://localhost:8099
```

## Model Management

Brain uses LM Studio CLI for model download and selection, but serves local models through `llama-server`.

After install:

```bash
~/Nymphs-Brain/bin/lms-model
~/Nymphs-Brain/bin/lms-start
```

The installer does not need to download a model by default. A model can be selected later from the custom manager page or by running `lms-model`.
The Manager `Manage Models` action opens the same `lms-model` script in a terminal.
The Manager `Start Brain` action starts the local LLM and MCP services. The `Open WebUI` action starts or opens only Open WebUI, preserving the standard module split between backend start and browser UI.

## Repo Rule

Keep this repo clean:

- keep installer scripts, wrapper scripts, docs, and `nymph.json`
- do not commit venvs
- do not commit `local-tools`
- do not commit model files
- do not commit Open WebUI databases
- do not commit logs
- do not commit secrets or API keys

## Current Source

The installer was copied from the working NymphsCore manager script:

```text
NymphsCore/Manager/scripts/install_nymphs_brain.sh
```

The remote LLM MCP bridge was copied from:

```text
NymphsCore/Manager/scripts/remote_llm_mcp/
```
