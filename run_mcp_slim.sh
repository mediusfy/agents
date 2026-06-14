#!/bin/sh
set -e

export OTEL_SDK_DISABLED=true

exec uvicorn orchestration.mcp_server:mcp.sse_app --host 0.0.0.0 --port 8002
