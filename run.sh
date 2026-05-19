#!/bin/bash
set -e

# Number of agent workers to start
NUM_WORKERS=${1:-2}

# Activate the virtual environment
source venv/bin/activate

# Start Redis container if not already running
if [ ! "$(docker ps -q -f name=openclaw-redis)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=openclaw-redis)" ]; then
        echo "Restarting existing Redis container..."
        docker start openclaw-redis
    else
        echo "Starting a new Redis container..."
        docker run -d --name openclaw-redis -p 6379:6379 redis
    fi
    # Wait for Redis to be ready
    sleep 3
fi

# Start the MCP server in the background
echo "Starting MCP server..."
uvicorn src.openclaw.mcp_server:mcp.app --host 0.0.0.0 --port 8000 &
MCP_PID=$!

# Start the Dagster dashboard in the background
echo "Starting Dagster dashboard..."
dagster-webserver -w src/openclaw/dagster_defs.py -h 0.0.0.0 -p 8080 &
DAGSTER_PID=$!

# Start the agent workers in the background
WORKER_PIDS=()
echo "Starting $NUM_WORKERS agent workers..."
for i in $(seq 1 $NUM_WORKERS); do
    python src/openclaw/worker.py &
    WORKER_PIDS+=($!)
done

echo "MCP Server running on port 8000 (PID: $MCP_PID)"
echo "Dagster dashboard running on port 8080 (PID: $DAGSTER_PID)"
echo "Agent workers running with PIDs: ${WORKER_PIDS[@]}"

# Function to shut down the services
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

# Trap script exit and call cleanup
trap cleanup EXIT

# Wait for the processes to exit
wait
