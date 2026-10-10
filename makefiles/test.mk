# makefiles/test.mk

VENV_DIR := ../agents/.venv

.PHONY: test-all
test-all: test-python test-go

.PHONY: test-python
test-python:
	@echo "--- Running Python tests ---"
	@(cd ../agents && .venv/bin/pytest)

GO_MODULES := $(shell find services -name "go.mod")

.PHONY: test-go
test-go:
	@echo "--- Running Go tests ---"
	@for mod in $(GO_MODULES); do \
		dir=$$(dirname $$mod); \
		echo "Running Go tests in $$dir..."; \
		(cd $$dir && go test ./...); \
	done