# Root Makefile

# Include all makefiles from the 'makefiles' directory
include $(wildcard makefiles/*.mk)

.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make help    - Show this help message"
	@echo "  make deps    - Download/sync all Python and Go dependencies"
	@echo "  make test-all- Run all tests (Python and Go)"