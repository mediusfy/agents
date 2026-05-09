VENV = .venv
PYTHON = $(VENV)/bin/python3
PIP = $(VENV)/bin/pip

# Load .env file if it exists
ifneq (,$(wildcard .env))
    include .env
    export
endif

.PHONY: run run-ba run-backend run-frontend run-test run-sre run-review \
        run-database run-devops run-docs run-security run-resume run-dry-run setup clean

PROJECT ?= default

run: $(VENV)
	@echo "=== Running full agent pipeline for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT)
	@echo "=== Pipeline complete. Artifacts in ./generated-app/$(PROJECT)/ ==="

run-resume: $(VENV)
	@echo "=== Resuming from last checkpoint for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT) --resume
	@echo "=== Pipeline complete. Artifacts in ./generated-app/$(PROJECT)/ ==="

run-ba: $(VENV)
	@echo "=== BA step ==="
	$(PYTHON) main.py --project $(PROJECT) --step ba

run-backend: $(VENV)
	@echo "=== Backend + Frontend step ==="
	$(PYTHON) main.py --project $(PROJECT) --step backend

run-frontend: $(VENV)
	@echo "=== Frontend step ==="
	$(PYTHON) main.py --project $(PROJECT) --step frontend

run-test: $(VENV)
	@echo "=== Test step ==="
	$(PYTHON) main.py --project $(PROJECT) --step test

run-sre: $(VENV)
	@echo "=== SRE step ==="
	$(PYTHON) main.py --project $(PROJECT) --step sre

run-review: $(VENV)
	@echo "=== Review step ==="
	$(PYTHON) main.py --project $(PROJECT) --step review

run-database: $(VENV)
	@echo "=== Database step ==="
	$(PYTHON) main.py --project $(PROJECT) --step database

run-devops: $(VENV)
	@echo "=== DevOps step ==="
	$(PYTHON) main.py --project $(PROJECT) --step devops

run-docs: $(VENV)
	@echo "=== Docs step ==="
	$(PYTHON) main.py --project $(PROJECT) --step docs

run-security: $(VENV)
	@echo "=== Security step ==="
	$(PYTHON) main.py --project $(PROJECT) --step security

run-dry-run: $(VENV)
	@echo "=== OpenClaw: Dry run (no LLM calls) for project: $(PROJECT) ==="
	$(PYTHON) main.py --project $(PROJECT) --dry-run --yes
	@echo "=== Dry run complete ==="

$(VENV):
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt

setup: $(VENV)
	@echo "=== Environment ready ==="
	@echo "  Python: $(shell $(PYTHON) --version)"
	
clean:
	@echo "=== Cleaning generated artifacts ==="
	rm -rf generated-app/
	@echo "Done."
