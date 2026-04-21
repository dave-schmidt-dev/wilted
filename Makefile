.PHONY: lint lint-sh test test-unit test-integration test-e2e test-tui validate install-launchd uninstall-launchd

lint:
	UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev ruff check .

lint-sh:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/wilted-nightly.sh && echo "shellcheck: OK"; \
	else \
		echo "shellcheck not found — install with: brew install shellcheck"; \
		exit 1; \
	fi

test:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev pytest

test-unit:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev pytest -m unit

test-integration:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev pytest -m integration

test-e2e:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev pytest -m e2e

test-tui:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --group dev pytest -m tui

validate: lint test

install-launchd:
	ln -sf $(CURDIR)/scripts/wilted-nightly.sh $(HOME)/.launchd/scripts/wilted_nightly.sh
	cp scripts/local.wilted-nightly.plist $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist || true
	@echo "Installed: wilted nightly at 2:00 AM via launchd"

uninstall-launchd:
	launchctl bootout gui/$$(id -u)/local.wilted-nightly 2>/dev/null || true
	rm -f $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist
	rm -f $(HOME)/.launchd/scripts/wilted_nightly.sh
	@echo "Uninstalled: wilted nightly launchd agent"
