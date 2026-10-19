.PHONY: lint deadcode test test-unit test-integration validate install-hooks

# One venv per checkout: the same one the app, the gate legs and
# `make worktree-setup` use. The `:=` deliberately overrides an exported
# UV_PROJECT_ENVIRONMENT so a shell setting cannot split the environments.
# The iCloud hidden-flag concern is guarded by tests/test_edge_cases.py in the
# preparation-runtime leg.
export UV_PROJECT_ENVIRONMENT := $(CURDIR)/.venv

# Static checkers reuse installed tools without loading unrelated runtime editables.
lint:
	"$(UV_PROJECT_ENVIRONMENT)/bin/ruff" check .

# Dead-code detection over src, baselined by vulture_allowlist.py (see the file
# header and pyproject [tool.vulture]). Fails only on NEW dead code past the
# baseline. Also runs as a pre-commit hook.
deadcode:
	"$(UV_PROJECT_ENVIRONMENT)/bin/python" -B -S -c 'import runpy,sys,sysconfig; env=sys.argv[1]; sys.path.insert(0,sysconfig.get_path("purelib",vars={"base":env,"platbase":env})); sys.argv=["vulture",*sys.argv[2:]]; runpy.run_module("vulture",run_name="__main__")' "$(UV_PROJECT_ENVIRONMENT)"

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
