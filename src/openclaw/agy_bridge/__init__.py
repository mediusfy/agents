"""Agy Bridge — extension layer that exposes pydantic_ai agents as native
Antigravity CLI (agy) subagents.

This package wraps the existing AgentRegistry without modifying any agent code.
It implements:
  - BridgeAgent: wraps a registered pydantic_ai agent for the agentapi protocol
  - agent_sync:  generates .agents/agent.json definitions for agy discovery
  - hooks:       Python-side hook decorators bridging agy's hook lifecycle
  - server:      JSON stdio sidecar speaking the agentapi protocol

Architecture:
  agy (cli/ide)
    │
    ├── MCP (existing, untouched)
    │   └── openclaw-agents → mcp_server.py → pydantic_ai agents
    │
    └── agentapi protocol
        └── agy_bridge_server.py → BridgeAgent → registry.query() → pydantic_ai agents

Usage:
    # Standalone:
    python -m openclaw.agy_bridge.server

    # Co-run with MCP server:
    python src/openclaw/mcp_server.py --with-bridge
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)
