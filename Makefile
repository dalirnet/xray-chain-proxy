# Default target
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

.PHONY: test
test: ## Run test suite
	@./test.sh

.PHONY: check-deps
check-deps: ## Check dependencies
	@command -v curl >/dev/null 2>&1 || { echo "✗ curl not found"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "✗ jq not found"; exit 1; }
	@command -v unzip >/dev/null 2>&1 || { echo "✗ unzip not found"; exit 1; }
	@command -v bash >/dev/null 2>&1 || { echo "✗ bash not found"; exit 1; }
	@echo "✓ All dependencies installed"

.PHONY: install
install: check-deps ## Install to /usr/local/bin/xcp (requires sudo)
	@if [ "$$(id -u)" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi
	@install -m 755 script.sh /usr/local/bin/xcp
	@echo "✓ Installed to /usr/local/bin/xcp"

.PHONY: uninstall
uninstall: ## Uninstall from /usr/local/bin/xcp (requires sudo)
	@if [ "$$(id -u)" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi
	@rm -f /usr/local/bin/xcp
	@echo "✓ Uninstalled"

.PHONY: clean
clean: ## Clean temporary files
	@rm -rf /tmp/xcp-test-*
	@rm -f script.sh.bak *.bak
	@echo "✓ Cleaned"

.PHONY: lint
lint: ## Check script syntax
	@bash -n script.sh && echo "✓ script.sh" || echo "✗ script.sh"
	@bash -n test.sh && echo "✓ test.sh" || echo "✗ test.sh"

.PHONY: version
version: ## Show version
	@grep '^readonly VERSION=' script.sh | cut -d'"' -f2
