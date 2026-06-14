#!/bin/bash
cd /workspace/entity-management
echo "=== Running go mod tidy ==="
go mod tidy 2>&1 
echo "=== Running go build ==="
go build ./... 2>&1
echo "=== Exit code: $? ==="
