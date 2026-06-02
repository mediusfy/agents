#!/bin/bash
set -e

cd "$(dirname "$0")"

source .venv/bin/activate
export LOGFIRE_SEND_TO_LOGFIRE=if-token-present
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

# Load environment variables from .env
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

mkdir -p "$DAGSTER_HOME"

# exec replaces the shell so stdin/stdout go directly to Python (no buffering)
exec python src/openclaw/agy_bridge/server.py
