#!/bin/bash
cd entity-management && go test ./internal/application/ -v -run "TestReadEntity" -count=1 2>&1