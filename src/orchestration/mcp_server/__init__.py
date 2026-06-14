"""Orgitration MCP Server — split into domain modules."""

import logging
import os

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from orchestration.observability import configure_observability

logger = logging.getLogger(__name__)

configure_observability()
logging.basicConfig(level=logging.INFO)

mcp = FastMCP(
    "Orgitration",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=os.environ.get("MCP_DNS_REBINDING_PROTECTION", "1") == "1"
    ),
)

from . import agent_tools, context_tools, memory_tools, pipeline_tools
from .agent_tools import AGENT_DOCSTRINGS, run_agent_by_name

__all__ = ["mcp", "AGENT_DOCSTRINGS", "run_agent_by_name"]
