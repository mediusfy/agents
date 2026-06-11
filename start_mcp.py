"""Startup script for the agents MCP server (production)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))


import uvicorn
from starlette.middleware.cors import CORSMiddleware

from orchestration.mcp_server import mcp

app = mcp.sse_app()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8002")))
