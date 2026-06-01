#!/bin/bash
set -e

cd "$(dirname "$0")"

NUM_WORKERS=${1:-2}

source .venv/bin/activate
export LOGFIRE_SEND_TO_LOGFIRE=if-token-present
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

mkdir -p "$DAGSTER_HOME"

# exec replaces the shell so stdin/stdout go directly to Python (no buffering)
exec python src/openclaw/mcp_server.py
