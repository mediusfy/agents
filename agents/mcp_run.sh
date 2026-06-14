#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Create venv if it doesn't exist
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -e ".[dev]"
else
    source .venv/bin/activate
fi

NUM_WORKERS=${1:-2}

export LOGFIRE_SEND_TO_LOGFIRE=if-token-present
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

mkdir -p "$DAGSTER_HOME"

# exec replaces the shell so stdin/stdout go directly to Python (no buffering)
exec python src/orchestration/mcp_server.py
