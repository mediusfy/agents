VENV = .venv
PYTHON = $(VENV)/bin/python3
PIP = $(VENV)/bin/pip

# Load .env file if it exists
ifneq (,$(wildcard .env))
    include .env
    export
endif

.PHONY: run run-ba run-backend run-frontend run-test run-sre run-review setup clean

run: $(VENV)
	@echo "=== OpenClaw: Running full agent pipeline ==="
	$(PYTHON) main.py
	@echo "=== Pipeline complete. Artifacts in ./generated-app/ ==="

run-ba: $(VENV)
	@echo "=== OpenClaw: BA step ==="
	$(PYTHON) main.py --step ba

run-backend: $(VENV)
	@echo "=== OpenClaw: Backend + Frontend step ==="
	$(PYTHON) main.py --step backend

run-frontend: $(VENV)
	@echo "=== OpenClaw: Frontend step ==="
	$(PYTHON) main.py --step frontend

run-test: $(VENV)
	@echo "=== OpenClaw: Test step ==="
	$(PYTHON) main.py --step test

run-sre: $(VENV)
	@echo "=== OpenClaw: SRE step ==="
	$(PYTHON) main.py --step sre

run-review: $(VENV)
	@echo "=== OpenClaw: Review step ==="
	$(PYTHON) main.py --step review

$(VENV):
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt

setup: $(VENV)
	@echo "=== OpenClaw: Environment ready ==="
	@echo "  Python: $(shell $(PYTHON) --version)"
	@echo "  To set API keys, copy .env.example to .env and fill in your keys."

clean:
	@echo "=== Cleaning generated artifacts ==="
	rm -rf generated-app/
	@echo "Done."
