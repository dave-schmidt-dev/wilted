.PHONY: lint deadcode test test-unit test-integration validate install-hooks

# Keep the project venv outside iCloud (~/Documents is iCloud-synced). iCloud sets the
# macOS UF_HIDDEN flag on .venv contents, and Python 3.13's site module silently skips
# hidden .pth files — which breaks the editable install. See HISTORY.md.
export UV_PROJECT_ENVIRONMENT := $(HOME)/.venvs/wilted

lint:
	uv run --group dev ruff check .

# Dead-code detection over src, baselined by vulture_allowlist.py (see the file
# header and pyproject [tool.vulture]). Fails only on NEW dead code past the
# baseline. Also runs as a pre-commit hook.
deadcode:
	uv run --group dev vulture

test:
	uv run --group dev python ../../scripts/run-bounded.py --timeout-seconds "$${WILTED_TEST_TIMEOUT_SECONDS:-1800}" -- pytest

test-unit:
	uv run --group dev python ../../scripts/run-bounded.py --timeout-seconds "$${WILTED_TEST_TIMEOUT_SECONDS:-1800}" -- pytest -m unit

test-integration:
	uv run --group dev python ../../scripts/run-bounded.py --timeout-seconds "$${WILTED_TEST_TIMEOUT_SECONDS:-1800}" -- pytest -m integration

validate: lint deadcode test

# Activate the repository-owned hooks in the root checkout. Required once per
# clone so `git commit` runs the fast lint/dead-code gate and `git push` runs
# the full project validation gate. Idempotent.
install-hooks:
	@bash "$(abspath $(CURDIR)/../../scripts/install-git-hooks.sh)"
