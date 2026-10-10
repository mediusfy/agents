# makefiles/deps.mk

VENV_DIR := ../agents/.venv

.PHONY: deps
deps: deps-python deps-go

.PHONY: deps-python
deps-python:
	@echo "--- Setting up Python dependencies ---"
	@if ! command -v uv &> /dev/null; then \
		echo "Error: uv is not installed. Please install it: https://github.com/astral-sh/uv"; \
		exit 1; \
	fi
	@if [ ! -d "$(VENV_DIR)" ]; then \
		echo "Creating Python virtual environment in $(VENV_DIR)..." ;\
		uv venv $(VENV_DIR); \
	fi
	@echo "Installing Python dependencies..."
	@$(VENV_DIR)/bin/uv pip sync pyproject.toml

GO_MODULES := $(shell find services -name "go.mod")

.PHONY: deps-go
deps-go:
	@echo "--- Setting up Go dependencies ---"
	@for mod in $(GO_MODULES); do \
		dir=$$(dirname $$mod); \
		echo "Tidying and downloading Go modules in $$dir..."; \
		(cd $$dir && go mod tidy && go mod download); \
	done
