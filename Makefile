VENV = .venv
PYTHON = $(VENV)/bin/python3
PIP = $(VENV)/bin/pip

# Fallback to system Python on CI where .venv doesn't exist
ifeq ($(wildcard $(VENV)),)
    PYTHON = python3
    PIP = pip3
endif

ifneq (,$(wildcard .env))
    include .env
    export
endif

.PHONY: all mcp run run-resume run-dry-run setup clean test lint build no-auto-run frontend-build

PROJECT ?= default


all: lint test

mcp: $(VENV)
	$(PYTHON) -m uvicorn openclaw.mcp_server:mcp.sse_app --host 0.0.0.0 --port 8002

mcp-stdio: $(VENV)
	$(PYTHON) -m openclaw.mcp_server

run: $(VENV)
	@echo "=== Running full agent pipeline for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT)
	@echo "=== Pipeline complete. Artifacts in ./generated-app/$(PROJECT)/ ==="

run-resume: $(VENV)
	@echo "=== Resuming from last checkpoint for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT) --resume
	@echo "=== Pipeline complete. Artifacts in ./generated-app/$(PROJECT)/ ==="

run-dry-run: $(VENV)
	@echo "=== OpenClaw: Dry run (no LLM calls) for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT) --dry-run --yes
	@echo "=== Dry run complete ==="

test:
	@echo "=== Running tests ==="
	$(PYTHON) -m pytest tests/ -v --cov=src/openclaw --cov-report=term-missing
	@echo "=== Tests complete ==="

lint:
	@echo "=== Running lint ==="
	$(PYTHON) -m ruff check src/ tests/
	$(PYTHON) -m ruff format --check src/ tests/
	$(PYTHON) -m mypy src/openclaw
	@echo "=== Lint passed ==="

# Frontend dev server (Vite), bypasses the generation pipeline
FRONTEND_DIR = generated-app/default/frontend

no-auto-run:
	@echo "=== Starting Rufkis Dashboard (no pipeline auto-run) ==="
	cd $(FRONTEND_DIR) && npm install && npm run dev

# Vite build for production
frontend-build:
	@echo "=== Building Rufkis Dashboard for production ==="
	cd $(FRONTEND_DIR) && npm ci && npm run build

build:
	$(PYTHON) -c "import openclaw; print('Build OK')"

$(VENV):
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -e ".[dev]"

setup: $(VENV)
	@echo "=== Environment ready ==="
	@echo "  Python: $(shell $(PYTHON) --version)"

clean:
	@echo "=== Cleaning generated artifacts ==="
	rm -rf generated-app/
	rm -rf .claw-checkpoints/
	@echo "Done."
