.PHONY: lint lint-sh test test-unit test-integration test-e2e test-tui validate

lint:
	UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra dev ruff check .

lint-sh:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/wilted-nightly.sh && echo "shellcheck: OK"; \
	else \
		echo "shellcheck not found — install with: brew install shellcheck"; \
		exit 1; \
	fi

test:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest

test-unit:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest -m unit

test-integration:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest -m integration

test-e2e:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest -m e2e

test-tui:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest -m tui

validate: lint test
