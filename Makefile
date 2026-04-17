.PHONY: lint test validate

lint:
	UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra dev ruff check .

test:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest

validate: lint test
