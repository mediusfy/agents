# Root Makefile

# Include all makefiles from the 'makefiles' directory
include $(wildcard makefiles/*.mk)

.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make help    - Show this help message"
