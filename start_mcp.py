"""Startup script for the agents MCP server (production)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

# Use vector_db stub if heavy ML deps are missing
try:
    import sentence_transformers  # noqa
except ImportError:
    import shutil
    shutil.copy(
        os.path.join(os.path.dirname(__file__), "src", "openclaw", "vector_db_stub.py"),
        os.path.join(os.path.dirname(__file__), "src", "openclaw", "vector_db.py"),
    )

# Disable FastMCP DNS rebinding protection (needed for cluster-internal access)
mcp_server_path = os.path.join(os.path.dirname(__file__), "src", "openclaw", "mcp_server.py")
with open(mcp_server_path) as f:
    src = f.read()
old = 'mcp = FastMCP("OpenClaw")'
new = (
    "from mcp.server.transport_security import TransportSecuritySettings\n"
    + 'mcp = FastMCP("OpenClaw", transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))'
)
src = src.replace(old, new)
with open(mcp_server_path, "w") as f:
    f.write(src)

from openclaw.mcp_server import mcp
from starlette.middleware.cors import CORSMiddleware

app = mcp.sse_app()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

import uvicorn

uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8002")))
