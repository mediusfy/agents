#!/bin/bash
set -e

cd "$(dirname "$0")"

NUM_WORKERS=${1:-2}

source .venv/bin/activate
export LOGFIRE_SEND_TO_LOGFIRE=false
export PYTHONPATH=$PYTHONPATH:$(pwd)/src
export DAGSTER_HOME=$(pwd)/.dagmem

mkdir -p "$DAGSTER_HOME"



if [ ! "$(docker ps -q -f name=openclaw-redis)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=openclaw-redis)" ]; then
        echo "Restarting existing Redis container..."
        docker start openclaw-redis
    else
        echo "Starting a new Redis container..."
        docker run -d --name openclaw-redis -p 6379:6379 redis
    fi
    sleep 3
fi

echo "Starting MCP server..."
uvicorn src.openclaw.mcp_server:mcp.sse_app --host 0.0.0.0 --port 8002 &
MCP_PID=$!

echo "Starting Dagster dashboard..."
dagster-webserver -m openclaw.dagster_defs -h 0.0.0.0 -p 8081 -d src &
DAGSTER_PID=$!

WORKER_PIDS=()
echo "Starting $NUM_WORKERS agent workers..."
for i in $(seq 1 $NUM_WORKERS); do
    python src/openclaw/worker.py &
    WORKER_PIDS+=($!)
done

echo "MCP Server running on port 8002 (PID: $MCP_PID)"
echo "Dagster dashboard running on port 8081 (PID: $DAGSTER_PID)"
echo "Agent workers running with PIDs: ${WORKER_PIDS[@]}"

cleanup() {
    echo "Shutting down services..."
    kill $MCP_PID
    kill $DAGSTER_PID
    for pid in "${WORKER_PIDS[@]}"; do
        kill $pid
    done
    echo "Stopping Redis container..."
    docker stop openclaw-redis
}

trap cleanup EXIT

wait
