#!/bin/bash
set -e

cd "$(dirname "$0")"

NUM_WORKERS=${1:-2}

source .venv/bin/activate
export LOGFIRE_SEND_TO_LOGFIRE=false
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

mkdir -p "$DAGSTER_HOME"

echo "Starting MCP server (stdio mode)..." >&2
# Actually run the MCP server using python and the stdio transport, not uvicorn which is for SSE
python src/openclaw/mcp_server.py
