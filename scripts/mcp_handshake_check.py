"""Smoke-test the openclaw MCP server by performing one initialize handshake
over stdio. Exits non-zero on any failure.

Used by `.github/workflows/ci.yml`'s mcp-test job. Catches regressions that
import-only checking misses: broken tool registration, MCP protocol-version
mismatches, missing transport deps.

We intentionally do NOT depend on the `mcp` client SDK here — that would just
re-exercise the same import path. Instead, spawn the server, write a raw JSON
initialize message to stdin, and assert the response carries the expected
serverInfo + at least one tool.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVER_MODULE = REPO_ROOT / "src" / "openclaw" / "mcp_server.py"
TIMEOUT_S = 60


def main() -> int:
    if not SERVER_MODULE.exists():
        print(f"FAIL: server entrypoint missing at {SERVER_MODULE}", file=sys.stderr)
        return 1

    # Invoke the server with the current interpreter rather than via mcp_run.sh.
    # CI installs deps into the system Python (no .venv); mcp_run.sh's
    # `source .venv/bin/activate` would otherwise exit non-zero before the
    # server boots.
    env = {**os.environ, "LOGFIRE_SEND_TO_LOGFIRE": "false"}
    src_path = str(REPO_ROOT / "src")
    env["PYTHONPATH"] = src_path + os.pathsep + env.get("PYTHONPATH", "")
    proc = subprocess.Popen(
        [sys.executable, str(SERVER_MODULE)],
        cwd=str(REPO_ROOT),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
    )

    handshake = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "ci-handshake-check", "version": "0.0.1"},
        },
    }
    try:
        stdout, stderr = proc.communicate(json.dumps(handshake) + "\n", timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        print(f"FAIL: MCP server did not respond within {TIMEOUT_S}s", file=sys.stderr)
        print("--- stderr ---", file=sys.stderr)
        print(stderr, file=sys.stderr)
        return 2

    # The server writes the JSON-RPC response on its first stdout line.
    first_line = next((line for line in stdout.splitlines() if line.strip().startswith("{")), None)
    if not first_line:
        print("FAIL: no JSON response on stdout", file=sys.stderr)
        print("--- stdout ---", file=sys.stderr)
        print(stdout, file=sys.stderr)
        print("--- stderr ---", file=sys.stderr)
        print(stderr, file=sys.stderr)
        return 3

    try:
        resp = json.loads(first_line)
    except json.JSONDecodeError as e:
        print(f"FAIL: stdout not JSON: {e}\nLine: {first_line!r}", file=sys.stderr)
        return 4

    result = resp.get("result", {})
    server_info = result.get("serverInfo", {})
    if server_info.get("name") != "OpenClaw":
        print(f"FAIL: serverInfo.name != 'OpenClaw': {server_info!r}", file=sys.stderr)
        return 5

    if "tools" not in result.get("capabilities", {}):
        print(f"FAIL: capabilities.tools missing: {result!r}", file=sys.stderr)
        return 6

    print(f"OK: handshake succeeded with {server_info.get('name')} v{server_info.get('version', '?')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
