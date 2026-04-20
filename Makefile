.PHONY: lint test test-slow validate

lint:
	UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra dev ruff check .

test:
	PYTHONPATH=src UV_CACHE_DIR=.uv-cache UV_PYTHON=python3.12 uv run --extra tui --extra test python -m pytest -m "not slow"

test-slow:
	PYTHONPATH=src ~/.venvs/mlx-audio/bin/python -m pytest -m slow -v

validate: lint test
