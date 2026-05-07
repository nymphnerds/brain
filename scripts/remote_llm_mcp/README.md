# Cached LLM MCP Server

## Manager-first setup

This bundle is now a tracked part of `NymphsCore` and is installed by the `Nymphs-Brain` Manager flow.

Normal setup path:

1. install `Nymphs-Brain` from NymphsCore Manager
2. open the `Brain` page
3. paste an OpenRouter key into the one-line `OpenRouter key` field
4. click `Apply Key`
5. open `Manage Models` and choose the remote `llm-wrapper` model
6. start Brain or run `Update Stack`

If no OpenRouter key is configured, Brain skips `llm-wrapper` and the rest of the stack still starts normally.

The shell scripts in this folder still exist as an advanced fallback for manual installs, but they are no longer the primary workflow.

## What is this?

`llm-wrapper` lets a local Brain model delegate one-shot hard tasks to a remote OpenRouter model such as GPT-4o, Claude, Gemini, or DeepSeek.

Think of it like this: your local model is the fast, private daily driver, while the cached wrapper is the optional heavy-lift path for harder reasoning. Identical prompts are cached locally so repeated calls are cheaper and faster.

---

## Why Use This?

| Local LLM (Your 27B Model) | Cloud LLM via cached llm-wrapper |
|---------------------------|----------------------------------|
| ✅ Free to run | 💰 Pay per use (pennies per call) |
| ✅ Fast responses | 🚀 Much smarter for complex tasks |
| ✅ Private (stays on your machine) | 🌐 Accesses the internet's best models |
| ❌ Limited reasoning power | ✅ Best-in-class AI capabilities + prompt caching |

**Best of both worlds:** Keep everyday tasks local and private, but delegate really hard problems to the world's smartest AI models. Identical prompts are cached locally to save API costs and speed up repeated calls.

---

## How It Works (Simplified)

```
┌─────────────────────────────────────┐
│         You type in Cline           │
└───────────────┬─────────────────────┘
                │
                ▼
┌─────────────────────────────────────┐
│  Your Local AI (27B model)          │ ← Handles most tasks
│                                     │
│  ┌───────────────────────────────┐  │
│  │ Complex task detected?        │  │
│  │ → Call llm_call tool          │  │
│  └───────────────┬───────────────┘  │
└──────────────────┼──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│  MCP Proxy (port 8100)              │ ← Routes request to llm-wrapper
└──────────────────┬──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│  Cached LLM MCP Server              │ ← Custom server with prompt caching
│  (cached_llm_mcp_server.py)         │
│                                     │
│  ┌─────────────────────────────┐    │
│  │ Prompt in cache?            │    │
│  │ YES → Return cached result  │ ← Instant response
│  │ NO  → Call OpenRouter API   │ ← First-time call (~1-2 min for free models)
│  └───────────────┬─────────────┘    │
└──────────────────┼──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│  OpenRouter API                     │ ← Connects to GPT-4o, Claude, etc.
└─────────────────────────────────────┘
```

### Prompt Caching

The server caches LLM responses using a local SQLite database:

- **Cache key**: SHA256 hash of `prompt + model`
- **Cache location**: `Nymphs-Brain/mcp/data/llm_cache/prompt_cache.sqlite`
- **Default TTL**: 3600 seconds (1 hour)
- **Default timeout**: 120 seconds (for first-time API calls)

This means identical prompts return instantly on subsequent calls, saving API costs.

---

## What you need before starting

1. ✅ **Nymphs-Brain installed** - The MCP proxy must be running
2. ✅ **Python 3.12+ virtual environment** - Located at `Nymphs-Brain/mcp-venv`
3. ✅ **OpenRouter.ai account** - Free sign-up at https://openrouter.ai
4. ✅ **OpenRouter API key** - A secret key starting with `sk-or-`

> 💡 **Getting an API Key:** Go to https://openrouter.ai/keys and create a new key. It's free to sign up!

---

## Recommended install path

Use NymphsCore Manager first:

- install Brain
- apply the OpenRouter key on the Brain page
- choose the remote model through `Manage Models`
- start Brain or run `Update Stack`

When enabled, Brain automatically:

- writes `Nymphs-Brain/secrets/llm-wrapper.env`
- installs the cached runtime into `Nymphs-Brain/local-tools/remote_llm_mcp`
- adds `llm-wrapper` to MCP and mcpo
- seeds the Open WebUI tool-server config
- keeps the wrapper out of the stack when no key exists

## Manual shell fallback

If you intentionally want to run the standalone shell flow instead of the Manager:

```bash
cd /path/to/remote_llm_mcp
chmod +x install-llm-wrapper.sh
./install-llm-wrapper.sh --dry-run
./install-llm-wrapper.sh
```

---

## Available Cloud AI Models

Choose one during installation, or change later:

| Number | Model | Best For | Cost |
|--------|-------|----------|------|
| 1 | `anthropic/claude-3.5-sonnet` | Coding & reasoning tasks | ~$3/1M tokens |
| 2 | `openai/gpt-4o` | All-purpose excellence | ~$5/1M tokens |
| 3 | `google/gemini-flash-1.5` | Fast, budget-friendly | ~$0.75/1M tokens |
| 4 | `deepseek/deepseek-chat` | Code generation | ~$0.27/1M tokens |
| 5 | `nvidia/nemotron-3-super-120b-a12b:free` | **FREE tier!** | Free (limited) |
| 6 | `anthropic/claude-3-haiku` | Quick responses | ~$0.25/1M tokens |
| 7 | `openai/gpt-4o-mini` | Lightweight GPT-4 | ~$0.15/1M tokens |
| 9 | **Custom** | Any OpenRouter model | Varies |

> 💡 **Token Pricing:** You won't spend much! One complex task might use 2,000-5,000 tokens (input + output), costing pennies. With prompt caching, repeated calls are free.

---

## Choosing the remote model

Manager now treats the remote wrapper model as part of the same `Manage Models` flow as the local GGUF model and context length.

Use `Manage Models` when you want to:

- pick a preset remote OpenRouter model
- enter a custom `provider/model` id
- clear the remote override

The saved remote model is written to the Brain `llm-wrapper` secrets file alongside the optional OpenRouter key.

## How to use it in Cline and Open WebUI

Once installed, the `llm_call` tool is automatically available to your local AI. You don't need to manually call it—**just ask for it!**

### Example Prompts:
> "Use the llm_call tool to get Claude's perspective on this code architecture."

> "This bug is really complex—delegate to GPT-4o via llm_call."

> "Ask the remote LLM to summarize these technical documents."

> "I need better reasoning here. Use llm_call with Claude 3.5 Sonnet."

### What Happens:
1. Your local AI recognizes it needs help
2. It calls `llm_call` with your question
3. The cached server checks if the prompt was already answered
4. If cached: instant response. If not: calls OpenRouter API (~1-2 min for free models)
5. Cloud AI responds and the result is cached for future use
6. Your local AI incorporates that answer into its response to you

### Available Tools

| Tool | Description |
|------|-------------|
| `llm_call` | **ONE-SHOT** query to the cloud LLM — returns a single answer and closes the connection. Will not enter a multi-turn conversation. (Cached) |
| `cache_stats` | View cache statistics (hits, misses, entries) |
| `cache_clear` | Clear all cached responses |

### One-Shot Mode (Prevents Multi-Turn Loops)

By default, when the local LLM calls `llm_call`, the response could be treated as a conversational turn — meaning the local LLM might call the tool again with a follow-up question, creating an endless loop of the two LLMs "arguing" with each other.

**One-shot mode solves this** by wrapping every response in clear framing:

```
=== REMOTE LLM RESPONSE (one-shot, connection closed) [cache: MISS] ===
2+2 equals 4.
=== END REMOTE LLM RESPONSE ===

INSTRUCTION: The connection to the remote LLM has been closed.
Process the answer above and respond directly to the user.
Do NOT call llm_call again or continue the conversation with the remote LLM.
```

This tells the local LLM:
1. The answer is complete and final
2. The connection to the remote LLM is closed
3. It should process the answer and respond to you — not call the tool again

## Direct test

If you want to verify the wrapper directly without relying on Open WebUI tool-calling behavior:

```bash
curl -s http://127.0.0.1:8099/llm-wrapper/llm_call \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Reply with exactly DIRECT_WRAPPER_TEST_OK and nothing else."}'
```

Run the same request twice:

- first response is typically `cache: MISS`
- second response should usually be `cache: HIT`

---

## Configuration Files

After installation, these files are created/modified:

| File | What's in It |
|------|--------------|
| `Nymphs-Brain/secrets/llm-wrapper.env` | **Your OpenRouter API key** (keep this secret!) |
| `Nymphs-Brain/bin/mcp-start` | MCP proxy config with llm-wrapper settings |
| `Nymphs-Brain/mcp/data/llm_cache/prompt_cache.sqlite` | Cached LLM responses |
| `~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` | Cline's list of available MCP servers |

> 🔒 **Security Note:** Your API key is stored in a `.env` file, not hardcoded into scripts. It starts with `sk-or-`.

---

## Changing the default model

Preferred path: use the Brain page `Manage Models` flow, then restart Brain or run `Update Stack`.

Manual fallback:

1. Open `Nymphs-Brain/secrets/llm-wrapper.env`
2. Find `REMOTE_LLM_MODEL=...`
3. Change it to any OpenRouter model id (for example `openai/gpt-4o` or `deepseek/deepseek-chat`)
4. Restart the MCP proxy:

```bash
cd Nymphs-Brain
./bin/mcp-stop && ./bin/mcp-start
```

### Changing Cache Settings

In `Nymphs-Brain/bin/mcp-start`, you can adjust:

| Argument | Default | Description |
|----------|---------|-------------|
| `--timeout` | `120` | Request timeout in seconds for API calls |
| `--cache-ttl` | `3600` | Cache entry lifetime in seconds (1 hour) |
| `--cache-dir` | `mcp/data/llm_cache` | Directory for the SQLite cache database |

---

## Uninstallation

To completely remove the cached LLM wrapper:

```bash
cd /path/to/remote_llm_mcp
chmod +x uninstall-llm-wrapper.sh
./uninstall-llm-wrapper.sh
```

**This removes:**
- The prompt cache directory (`mcp/data/llm_cache/`)
- Your API key from secrets folder
- llm-wrapper config from MCP proxy
- Entry from Cline's MCP settings

---

## Troubleshooting

### ❓ "I don't see the llm_call tool in Cline"
```bash
# Check if MCP proxy is running
curl http://127.0.0.1:8100/status

# Check if llm-wrapper OpenAPI is exposed
curl http://127.0.0.1:8099/llm-wrapper/openapi.json

# Restart Cline to reload MCP servers
```

### ❓ "Invalid API key" or authentication errors
- Verify your OpenRouter key is correct (should start with `sk-or-`)
- Check the secrets file: `cat Nymphs-Brain/secrets/llm-wrapper.env`
- Ensure you didn't add extra spaces when pasting the key

### ❓ "Model not responding" or timeout
- The free model might have long queue times — the default timeout is 120s
- Increase timeout in `mcp-start`: change `--timeout 120` to a higher value
- Try a different (paid) model for faster responses
- Check OpenRouter status: https://openrouter.ai/status

### ❓ "Cache not working" or stale responses
- Check cache stats via the `cache_stats` tool in Cline
- Clear the cache via the `cache_clear` tool
- Or manually remove: `rm Nymphs-Brain/mcp/data/llm_cache/prompt_cache.sqlite`

### ❓ MCP proxy won't start after installation
```bash
# Restore from backup
cd Nymphs-Brain
cp bin/mcp-start.original bin/mcp-start

# Re-run the installer with different options
./install-llm-wrapper.sh
```

---

## Technical Notes (For Developers)

### Architecture

This replaces the original `llm-wrapper-mcp-server` pip package with a custom Python script (`cached_llm_mcp_server.py`) that provides:

1. **Prompt caching** — SHA256 hash of `prompt|model` as cache key, stored in SQLite with TTL expiry
2. **Configurable timeout** — Default 120s (the old package had a hard 30s timeout)
3. **Three tools** — `llm_call`, `cache_stats`, `cache_clear`
4. **No external dependencies** — Uses only Python standard library (`httpx`-free, uses `urllib`/`http.client`)

### Why Not the pip Package?

The original `llm-wrapper-mcp-server` (v0.1.3) had issues:
- **30s hard timeout** — Insufficient for free-tier models with queue times
- **No caching** — Every identical prompt cost API credits
- **MCP protocol bugs** — Required patching to work with Cline's proxy
- **Multi-turn loop problem** — The local and remote LLMs would get into an endless conversation loop, each responding to the other's output

The custom server solves all of these without requiring any patches, and adds **one-shot response framing** to prevent multi-turn loops.

### Migration Guide: From Old pip Package to New Cached Server

If you previously had the `llm-wrapper-mcp-server` pip package installed and want to migrate to the new custom cached server:

**What changes:**

| Aspect | Old (pip package) | New (custom cached server) |
|--------|-------------------|----------------------------|
| Installation | `pip install llm-wrapper-mcp-server` + `patch-llm-wrapper.py` | Python script only, no pip package needed |
| Timeout | 30s (hard-coded) | 120s (configurable via `--timeout`) |
| Caching | None | SQLite prompt cache with TTL |
| Multi-turn behavior | LLMs could loop endlessly | One-shot framing prevents loops |
| Dependencies | `httpx`, `mcp-server` framework | Only `requests` (already in mcp-venv) |

**Step-by-step migration:**

```bash
cd /path/to/remote_llm_mcp

# Step 1: Uninstall the old pip package (if still installed)
Nymphs-Brain/mcp-venv/bin/pip uninstall -y llm-wrapper-mcp-server

# Step 2: Run the uninstall script to clean up old config
chmod +x uninstall-llm-wrapper.sh
./uninstall-llm-wrapper.sh

# Step 3: Run the new installer (installs cached server with one-shot mode)
chmod +x install-llm-wrapper.sh
./install-llm-wrapper.sh
```

That's it. The installer handles everything: creating the cache directory, updating `mcp-start` to point to `cached_llm_mcp_server.py`, configuring Cline settings, and restarting the MCP stack.

**After migration, verify:**
```bash
# Test the one-shot response
curl -s http://127.0.0.1:8099/llm-wrapper/llm_call \
  -X POST -H "Content-Type: application/json" \
  -d '{"prompt":"What is 2+2? One sentence only."}'
```

You should see the response wrapped in `=== REMOTE LLM RESPONSE ===` markers with the one-shot instruction.

### Files in This Package

| File | Purpose |
|------|---------|
| `install-llm-wrapper.sh` | Interactive installer with automatic configuration |
| `uninstall-llm-wrapper.sh` | Clean removal script |
| `cached_llm_mcp_server.py` | The custom MCP server with prompt caching |
| `README.md` | This documentation |
| `patch-llm-wrapper.py` | *(Legacy)* MCP protocol fix for the old pip package (no longer needed) |
| `uninstall-llm-wrapper.sh` | Clean removal script |

---

## Deploying to Another Computer

To set this up on a different machine:

1. Copy the entire `remote_llm_mcp` folder to the target PC
2. Ensure Nymphs-Brain is installed with the same directory structure
3. Follow the installation steps above

---

## WSL (Windows Subsystem for Linux) Support

The installer automatically detects if you're running in WSL and configures accordingly.

### How It Works

| Environment | MCP Host Binding | Notes |
|-------------|-----------------|-------|
| **Native Linux** | `127.0.0.1` (localhost only) | More secure - only local access |
| **WSL** | `0.0.0.0` (all interfaces) | Allows Windows apps to access via localhost |

### Detection Method

The installer checks `/proc/version` for "Microsoft" to determine if running in WSL:

```bash
grep -qi microsoft /proc/version && echo "WSL detected"
```

### What Happens in WSL Mode

1. **MCP proxy binds to `0.0.0.0`** - This allows Windows applications to connect
2. **Cline still uses `http://127.0.0.1:8100`** - Windows sees this as localhost (automatic port forwarding)
3. **No manual configuration needed** - Everything is handled automatically

### Manual WSL Configuration (if auto-detection fails)

If for some reason the installer doesn't detect WSL correctly, you can manually set:

```bash
export NYMPHS_BRAIN_MCP_HOST=0.0.0.0
./install-llm-wrapper.sh
```

Or add to your `~/.bashrc`:

```bash
# For WSL MCP compatibility
export NYMPHS_BRAIN_MCP_HOST=0.0.0.0
```

### Verifying WSL Installation

After installation, verify the MCP proxy is accessible from Windows:

1. **In WSL terminal:**
   ```bash
   curl http://127.0.0.1:8100/status
   ```

2. **In Windows PowerShell:**
   ```powershell
   curl http://localhost:8100/status
   ```

Both should return the MCP proxy status.

### WSL Networking Troubleshooting

If Windows cannot access the MCP proxy:

1. **Check binding address in WSL:**
   ```bash
   netstat -tlnp | grep 8100
   ```
   Should show `0.0.0.0:8100` not `127.0.0.1:8100`

2. **Restart MCP proxy with explicit host:**
   ```bash
   cd Nymphs-Brain
   NYMPHS_BRAIN_MCP_HOST=0.0.0.0 ./bin/mcp-start
   ```

3. **Check Windows firewall** - Ensure no rules block port 8100

---

## Need Help?

- **OpenRouter documentation:** https://openrouter.ai/docs
- **MCP Protocol spec:** https://modelcontextprotocol.io/
- **WSL networking guide:** https://learn.microsoft.com/en-us/windows/wsl/networking

---

**License:** MIT License
