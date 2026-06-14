.PHONY: checks

# Disable OpenTelemetry exporting during checks to prevent unauthorized/bad request errors
export OTEL_SDK_DISABLED=true
export LOGFIRE_IGNORE_NO_CONFIG=1

checks:
	@echo "=== Replicating CI/CD pipeline locally ==="
	@echo "-> Running lint checks..."
	$(MAKE) -C agents lint
	@echo "-> Running tests..."
	$(MAKE) test-all
	@echo "-> Running MCP server smoke tests..."
	cd agents && .venv/bin/python -c "from orchestration.mcp_server import mcp; print('MCP server imports OK')"
	cd agents && .venv/bin/python scripts/mcp_handshake_check.py
	@echo "=== All checks passed! ==="
