#!/bin/bash
# start.sh - Run Semantic Router Gateway

# Get the script directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Activate virtualenv
source "$DIR/venv/bin/activate"

# Export LiteLLM URL environment variable
export LITELLM_URL="http://localhost:4000"

echo "[Semantic Router] Starting on port 5001..."
uvicorn main:app --host 0.0.0.0 --port 5001
