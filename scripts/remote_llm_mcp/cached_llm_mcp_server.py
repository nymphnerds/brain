#!/usr/bin/env python3
"""
Cached LLM MCP Server - STDIO-based MCP server with prompt caching.

Features:
- SHA256-based prompt caching with SQLite backend
- TTL-based cache expiry (default 1 hour)
- Increased timeout (120s) for complex prompts
- Direct OpenRouter API calls
- MCP protocol compliant (stdio transport)

Usage:
    python -m cached_llm_mcp_server --model <model_name> --cache-dir <path> --timeout <seconds> --cache-ttl <seconds>
"""

import json
import sys
import os
import hashlib
import time
import sqlite3
import argparse
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional
from datetime import datetime, timezone

try:
    import requests
except ImportError:
    print("Error: 'requests' package required. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging – write to stderr so it doesn't pollute the MCP stdio channel
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("cached_llm_mcp")

# ---------------------------------------------------------------------------
# Cache layer
# ---------------------------------------------------------------------------

class PromptCache:
    """SQLite-backed prompt response cache with TTL expiry."""

    def __init__(self, cache_dir: str = None, ttl_seconds: int = 3600):
        self.ttl = ttl_seconds
        if cache_dir is None:
            cache_dir = os.path.join(os.getcwd(), "data", "llm_cache")
        os.makedirs(cache_dir, exist_ok=True)
        self.db_path = os.path.join(cache_dir, "prompt_cache.sqlite")
        self._init_db()

    def _init_db(self):
        with sqlite3.connect(self.db_path) as con:
            con.execute("""
                CREATE TABLE IF NOT EXISTS cache (
                    hash      TEXT PRIMARY KEY,
                    prompt    TEXT NOT NULL,
                    response  TEXT NOT NULL,
                    model     TEXT NOT NULL DEFAULT '',
                    created   REAL NOT NULL
                )
            """)
            # Periodic cleanup – delete expired rows
            con.execute("DELETE FROM cache WHERE created < ?", (time.time() - self.ttl,))
            con.commit()

    def _make_hash(self, prompt: str, model: str) -> str:
        raw = f"{prompt}|{model}".encode("utf-8")
        return hashlib.sha256(raw).hexdigest()

    def get(self, prompt: str, model: str) -> Optional[str]:
        h = self._make_hash(prompt, model)
        with sqlite3.connect(self.db_path) as con:
            row = con.execute(
                "SELECT response, created FROM cache WHERE hash = ?", (h,)
            ).fetchone()
        if row is None:
            return None
        response_text, created = row
        if time.time() - created > self.ttl:
            # Expired – delete and treat as miss
            with sqlite3.connect(self.db_path) as con:
                con.execute("DELETE FROM cache WHERE hash = ?", (h,))
            return None
        logger.info("Cache HIT for prompt (%s, %d chars)", model, len(prompt))
        return response_text

    def put(self, prompt: str, model: str, response: str):
        h = self._make_hash(prompt, model)
        with sqlite3.connect(self.db_path) as con:
            con.execute(
                "INSERT OR REPLACE INTO cache (hash, prompt, response, model, created) VALUES (?, ?, ?, ?, ?)",
                (h, prompt, response, model, time.time()),
            )
            con.commit()
        logger.info("Cache STORE for prompt (%s, %d chars)", model, len(prompt))

    def stats(self) -> Dict[str, Any]:
        with sqlite3.connect(self.db_path) as con:
            total = con.execute("SELECT COUNT(*) FROM cache").fetchone()[0]
            expired = con.execute(
                "SELECT COUNT(*) FROM cache WHERE created < ?", (time.time() - self.ttl,)
            ).fetchone()[0]
        return {"total_entries": total, "expired_entries": expired, "db_path": self.db_path}


# ---------------------------------------------------------------------------
# LLM client – calls OpenRouter
# ---------------------------------------------------------------------------

class OpenRouterClient:
    """Minimal OpenRouter chat-completions client."""

    def __init__(
        self,
        api_key: str,
        base_url: str,
        model: str,
        system_prompt: str = "",
        timeout: int = 120,
    ):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.system_prompt = system_prompt
        self.timeout = timeout
        self.headers = {
            "Authorization": f"Bearer {api_key}",
            "HTTP-Referer": "https://github.com/Nymphs-Brain",
            "X-Title": "Cached LLM MCP Server",
            "Content-Type": "application/json",
        }

    def generate(self, prompt: str, model_override: Optional[str] = None) -> str:
        model = model_override or self.model
        messages: List[Dict[str, str]] = []
        if self.system_prompt:
            messages.append({"role": "system", "content": self.system_prompt})
        messages.append({"role": "user", "content": prompt})

        payload = {
            "model": model,
            "messages": messages,
        }

        logger.info("Calling OpenRouter model=%s timeout=%ds prompt_len=%d", model, self.timeout, len(prompt))

        resp = requests.post(
            f"{self.base_url}/chat/completions",
            headers=self.headers,
            json=payload,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        data = resp.json()

        if not isinstance(data.get("choices"), list) or len(data["choices"]) == 0:
            raise RuntimeError(f"Invalid API response: no choices in {data}")

        content = data["choices"][0].get("message", {}).get("content", "")
        if not content:
            raise RuntimeError("Invalid API response: empty message content")

        # Log usage headers
        usage_info = {
            "total_tokens": resp.headers.get("X-Total-Tokens"),
            "prompt_tokens": resp.headers.get("X-Prompt-Tokens"),
            "completion_tokens": resp.headers.get("X-Completion-Tokens"),
            "total_cost": resp.headers.get("X-Total-Cost"),
        }
        logger.info("OpenRouter response: %s", usage_info)

        return content


# ---------------------------------------------------------------------------
# MCP server (stdio transport)
# ---------------------------------------------------------------------------

class CachedLLMMCP:
    """MCP server that wraps OpenRouter with prompt caching."""

    def __init__(
        self,
        model: str,
        api_key: str,
        base_url: str,
        system_prompt: str = "",
        timeout: int = 120,
        cache_dir: str = None,
        cache_ttl: int = 3600,
        server_name: str = "cached-llm-mcp-server",
        server_version: str = "1.0.0",
    ):
        self.model = model
        self.server_name = server_name
        self.server_version = server_version
        self.cache = PromptCache(cache_dir=cache_dir, ttl_seconds=cache_ttl)
        self.client = OpenRouterClient(
            api_key=api_key,
            base_url=base_url,
            model=model,
            system_prompt=system_prompt,
            timeout=timeout,
        )

        self.tools = {
            "llm_call": {
                "description": "ONE-SHOT query to the configured LLM. This tool returns a single, final answer and then the connection to the remote LLM is closed. Do NOT call this tool multiple times in a conversation — use it once, take the answer, and respond to the user. Responses are cached to avoid redundant API calls.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "prompt": {
                            "type": "string",
                            "description": "The natural language prompt for the LLM.",
                        },
                        "model": {
                            "type": "string",
                            "description": "Optional model name override (e.g., 'openai/gpt-4o'). Must contain a '/' separator.",
                        },
                    },
                    "required": ["prompt"],
                },
            },
            "cache_stats": {
                "description": "Return statistics about the prompt cache (total entries, expired entries, cache file path).",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "required": [],
                },
            },
            "cache_clear": {
                "description": "Clear all cached prompt responses.",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "required": [],
                },
            },
        }

    # -- response formatting -----------------------------------------------

    @staticmethod
    def _format_one_shot_response(response_text: str, cache_status: str) -> str:
        """Wrap the LLM response with clear one-shot framing to prevent multi-turn loops.

        The local LLM (e.g. Open WebUI agent) sees this structured response and
        understands it is a final answer — not a conversational turn to continue.
        """
        return (
            f"=== REMOTE LLM RESPONSE (one-shot, connection closed) [cache: {cache_status}] ===\n"
            f"{response_text}\n"
            f"=== END REMOTE LLM RESPONSE ===\n\n"
            f"INSTRUCTION: The connection to the remote LLM has been closed. "
            f"Process the answer above and respond directly to the user. "
            f"Do NOT call llm_call again or continue the conversation with the remote LLM."
        )

    # -- stdout helpers -----------------------------------------------------

    @staticmethod
    def _write(msg: Dict[str, Any]):
        raw = json.dumps(msg) + "\n"
        sys.stdout.write(raw)
        sys.stdout.flush()

    def _respond(self, request_id: Any, result: Dict[str, Any]):
        self._write({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": result,
        })

    def _error(self, request_id: Any, code: int, message: str, data: str = ""):
        self._write({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {
                "code": code,
                "message": message,
                "data": data,
            },
        })

    # -- request handlers ---------------------------------------------------

    def handle_initialize(self, params: Dict, request_id: Any):
        self._respond(request_id, {
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {},
                "resources": {},
                "prompts": {},
            },
            "serverInfo": {
                "name": self.server_name,
                "version": self.server_version,
            },
        })

    def handle_tools_list(self, _params: Dict, request_id: Any):
        tools_list = [
            {"name": name, **defs}
            for name, defs in self.tools.items()
        ]
        self._respond(request_id, {"tools": tools_list})

    def handle_tools_call(self, params: Dict, request_id: Any):
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name == "llm_call":
            self._handle_llm_call(arguments, request_id)
        elif tool_name == "cache_stats":
            self._handle_cache_stats(arguments, request_id)
        elif tool_name == "cache_clear":
            self._handle_cache_clear(arguments, request_id)
        else:
            self._error(request_id, -32601, "Tool not found", f"Unknown tool '{tool_name}'")

    def _handle_llm_call(self, arguments: Dict, request_id: Any):
        prompt = arguments.get("prompt", "")
        if not prompt:
            self._error(request_id, -32602, "Invalid params", "Missing required 'prompt' argument")
            return

        model_override = arguments.get("model")
        model_to_use = self.model

        if model_override:
            model_override = model_override.strip()
            if not model_override or "/" not in model_override:
                self._error(request_id, -32602, "Invalid model", "Model must be in 'provider/name' format")
                return
            model_to_use = model_override

        # -- Check cache first -------------------------------------------
        cached = self.cache.get(prompt, model_to_use)
        if cached is not None:
            self._respond(request_id, {
                "content": [{"type": "text", "text": self._format_one_shot_response(cached, "HIT")}],
                "isError": False,
                "_cache": "HIT",
            })
            return

        # -- Call OpenRouter ---------------------------------------------
        try:
            response_text = self.client.generate(prompt, model_override=model_to_use)
        except requests.exceptions.Timeout:
            self._error(request_id, -32000, "Timeout", f"LLM call exceeded {self.client.timeout}s timeout")
            return
        except requests.exceptions.HTTPError as e:
            status = e.response.status_code if e.response is not None else "unknown"
            self._error(request_id, -32000, "HTTP error", f"OpenRouter returned {status}: {e.response.text if e.response else str(e)}")
            return
        except requests.exceptions.RequestException as e:
            self._error(request_id, -32000, "Network error", str(e))
            return
        except RuntimeError as e:
            self._error(request_id, -32000, "API error", str(e))
            return

        # -- Store in cache ----------------------------------------------
        self.cache.put(prompt, model_to_use, response_text)

        self._respond(request_id, {
            "content": [{"type": "text", "text": self._format_one_shot_response(response_text, "MISS")}],
            "isError": False,
            "_cache": "MISS",
        })

    def _handle_cache_stats(self, _arguments: Dict, request_id: Any):
        stats = self.cache.stats()
        self._respond(request_id, {
            "content": [{"type": "text", "text": json.dumps(stats, indent=2)}],
            "isError": False,
        })

    def _handle_cache_clear(self, _arguments: Dict, request_id: Any):
        if os.path.exists(self.cache.db_path):
            os.remove(self.cache.db_path)
            self.cache._init_db()
        self._respond(request_id, {
            "content": [{"type": "text", "text": "Cache cleared."}],
            "isError": False,
        })

    # -- main dispatch -----------------------------------------------------

    def handle_request(self, request: Dict[str, Any]):
        method = request.get("method", "")
        request_id = request.get("id")
        params = request.get("params", {})

        try:
            if method == "initialize":
                self.handle_initialize(params, request_id)
            elif method == "tools/list":
                self.handle_tools_list(params, request_id)
            elif method == "tools/call":
                self.handle_tools_call(params, request_id)
            elif method in ("resources/list", "prompts/list"):
                self._respond(request_id, {"tools" if method == "tools/list" else method.split("/")[0] + "s": []})
            else:
                self._error(request_id, -32601, "Method not found", f"Unknown method '{method}'")
        except Exception as e:
            logger.exception("Unhandled error in request handler")
            self._error(request_id, -32000, "Internal error", str(e))

    def run(self):
        """Main loop – read JSON-RPC requests from stdin."""
        logger.info("Starting %s v%s (model=%s, timeout=%ds, cache_ttl=%ds)",
                     self.server_name, self.server_version, self.model,
                     self.client.timeout, self.cache.ttl)

        while True:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                self.handle_request(request)
            except json.JSONDecodeError:
                self._error(None, -32700, "Parse error", "Invalid JSON")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Cached LLM MCP Server")
    p.add_argument("--model", default="nvidia/nemotron-3-super-120b-a12b:free",
                   help="Default OpenRouter model to use")
    p.add_argument("--timeout", type=int, default=120,
                   help="HTTP timeout in seconds for OpenRouter calls (default 120)")
    p.add_argument("--cache-ttl", type=int, default=3600,
                   help="Cache time-to-live in seconds (default 3600 = 1 hour)")
    p.add_argument("--cache-dir", default=None,
                   help="Directory for cache SQLite DB (default: ./data/llm_cache)")
    p.add_argument("--system-prompt", default="",
                   help="Optional system prompt text")
    p.add_argument("--system-prompt-file", default="",
                   help="Path to file containing system prompt")
    p.add_argument("--limit-user-prompt-length", type=int, default=4000,
                   help="Max token length for user prompts (default 4000)")
    return p.parse_args()


def main():
    args = parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY", "")
    if not api_key:
        logger.error("OPENROUTER_API_KEY environment variable not set")
        sys.exit(1)

    base_url = os.environ.get("LLM_API_BASE_URL", "https://openrouter.ai/api/v1")

    system_prompt = args.system_prompt
    if args.system_prompt_file and os.path.exists(args.system_prompt_file):
        with open(args.system_prompt_file, "r") as f:
            system_prompt = f.read()

    server = CachedLLMMCP(
        model=args.model,
        api_key=api_key,
        base_url=base_url,
        system_prompt=system_prompt,
        timeout=args.timeout,
        cache_dir=args.cache_dir,
        cache_ttl=args.cache_ttl,
    )
    server.run()


if __name__ == "__main__":
    main()