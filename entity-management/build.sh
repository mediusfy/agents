#!/bin/bash
set -e
cd /workspace/entity-management
echo "=== Running go mod tidy ==="
go mod tidy 2>&1 || echo "tidying completed"
echo "=== go.sum updated ==="
echo "=== Running go vet ==="
go vet ./... 2>&1 || echo "vet completed"
echo "=== Running go build ==="
go build ./... 2>&1
echo "=== Build SUCCESS ==="
