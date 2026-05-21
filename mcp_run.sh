#!/bin/bash
set -e

cd "$(dirname "$0")"

NUM_WORKERS=${1:-2}

source .venv/bin/activate
export LOGFIRE_SEND_TO_LOGFIRE=false
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

mkdir -p "$DAGSTER_HOME"

echo "Starting MCP server (SSE mode)..."
uvicorn openclaw.mcp_server:mcp.sse_app --host 0.0.0.0 --port 8002 &
MCP_PID=$!

echo "MCP Server running on port 8002 (PID: $MCP_PID)"

cleanup() {
    echo "Shutting down services..."
    kill $MCP_PID 2>/dev/null || true
}

trap cleanup EXIT

wait
