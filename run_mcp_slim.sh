#!/bin/sh
set -e

# If heavy ML deps are missing, replace vector_db with lightweight stub
if ! python3 -c "import sentence_transformers" 2>/dev/null; then
  echo "Heavy ML deps not installed — using vector_db stub"
  AGENTS_DIR=$(python3 -c "import openclaw; import os; print(os.path.dirname(openclaw.__file__))")
  cp "$AGENTS_DIR/vector_db_stub.py" "$AGENTS_DIR/vector_db.py"
fi

exec uvicorn openclaw.mcp_server:mcp.sse_app --host 0.0.0.0 --port 8002
