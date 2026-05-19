#!/bin/bash
set -e

# Activate the virtual environment
source venv/bin/activate

# Start the MCP server in the background
echo "Starting MCP server..."
uvicorn src.openclaw.mcp_server:mcp.app --host 0.0.0.0 --port 8000 &
MCP_PID=$!

# Start the Dagster dashboard in the background
echo "Starting Dagster dashboard..."
dagster-webserver -w src/openclaw/dagster_defs.py -h 0.0.0.0 -p 8080 &
DAGSTER_PID=$!

echo "MCP Server running on port 8000 (PID: $MCP_PID)"
echo "Dagster dashboard running on port 8080 (PID: $DAGSTER_PID)"

# Function to shut down the services
cleanup() {
    echo "Shutting down services..."
    kill $MCP_PID
    kill $DAGSTER_PID
}

# Trap script exit and call cleanup
trap cleanup EXIT

# Wait for the processes to exit
wait
