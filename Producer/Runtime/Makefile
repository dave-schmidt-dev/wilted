.PHONY: lint deadcode test test-unit test-integration test-e2e test-tui validate install-hooks station station-test install-daemon

# Well-known path for the A.5.1 manual weather-bulletin test trigger. `touch`
# this file (from another shell) while the station is running under
# `make station-test` to fire a real, fully-synthesized weather bulletin.
WEATHER_TEST_TRIGGER := ../../.logs/wilted-fire-bulletin

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

test-e2e:
	uv run --group dev python ../../scripts/run-bounded.py --timeout-seconds "$${WILTED_TEST_TIMEOUT_SECONDS:-1800}" -- pytest -m e2e

test-tui:
	uv run --group dev python ../../scripts/run-bounded.py --timeout-seconds "$${WILTED_TEST_TIMEOUT_SECONDS:-1800}" -- pytest -m tui

validate: lint deadcode test

# Activate the repository-owned hooks in the root checkout. Required once per
# clone so `git commit` runs the fast lint/dead-code gate and `git push` runs
# the full project validation gate. Idempotent.
install-hooks:
	@bash "$(abspath $(CURDIR)/../../scripts/install-git-hooks.sh)"

# Keep the recovery command advertised by the daemon-only TTS error contract
# in the sibling speech-stack project, where the launchd service is owned.
install-daemon:
	$(MAKE) -C $(abspath $(CURDIR)/../speech-stack) install-daemon

# Launch the interactive station TUI (live-NWS weather monitor — a real
# Severe/Tornado NWS alert is required for a bulletin to fire).
station:
	PYTHONPATH=src uv run --group dev python -m wilted.cli

# Launch the station with the A.5.1 weather-bulletin TEST TRIGGER armed. This
# is the ONLY launch in which `touch $(WEATHER_TEST_TRIGGER)` fires a bulletin;
# a plain `wilted`/`make station` launch runs live-NWS mode and ignores that
# file entirely. The weather status line + the WARNING log line both confirm
# "TEST TRIGGER" mode at startup.
station-test:
	@mkdir -p ../../.logs
	@echo "Station arming A.5.1 test trigger. In ANOTHER shell run:  touch $(WEATHER_TEST_TRIGGER)"
	@echo "to fire a weather bulletin (interrupts within ~30s at the next safe transcript boundary)."
	WILTED_WEATHER_TEST_TRIGGER=$(WEATHER_TEST_TRIGGER) PYTHONPATH=src uv run --group dev python -m wilted.cli
