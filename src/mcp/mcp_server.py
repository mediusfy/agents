"""Legacy MCP server — delegates to the unified server in openclaw.mcp_server.

This file exists for backward compatibility. New code should import from
openclaw.mcp_server directly.
"""

import sys

from openclaw.mcp_server import mcp

if __name__ == "__main__":
    print("Starting MCP server (unified)...", file=sys.stderr)
    mcp.run()
