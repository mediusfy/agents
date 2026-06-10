#!/bin/bash
cd /workspace/entity-management
go mod tidy 2>&1 || true
go build ./... 2>&1 || true
