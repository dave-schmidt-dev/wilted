.PHONY: lint lint-sh test test-unit test-integration test-e2e test-tui validate station station-test install-daemon install-launchd uninstall-launchd

# Well-known path for the A.5.1 manual weather-bulletin test trigger. `touch`
# this file (from another shell) while the station is running under
# `make station-test` to fire a real, fully-synthesized weather bulletin.
WEATHER_TEST_TRIGGER := /tmp/wilted-fire-bulletin

# Keep the project venv outside iCloud (~/Documents is iCloud-synced). iCloud sets the
# macOS UF_HIDDEN flag on .venv contents, and Python 3.13's site module silently skips
# hidden .pth files — which breaks the editable install. See HISTORY.md.
export UV_PROJECT_ENVIRONMENT := $(HOME)/.venvs/wilted

lint:
	uv run --group dev ruff check .

lint-sh:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/wilted-nightly.sh && echo "shellcheck: OK"; \
	else \
		echo "shellcheck not found — install with: brew install shellcheck"; \
		exit 1; \
	fi

test:
	uv run --group dev pytest

test-unit:
	uv run --group dev pytest -m unit

test-integration:
	uv run --group dev pytest -m integration

test-e2e:
	uv run --group dev pytest -m e2e

test-tui:
	uv run --group dev pytest -m tui

validate: lint test

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
	@echo "Station arming A.5.1 test trigger. In ANOTHER shell run:  touch $(WEATHER_TEST_TRIGGER)"
	@echo "to fire a weather bulletin (interrupts within ~30s at the next safe transcript boundary)."
	WILTED_WEATHER_TEST_TRIGGER=$(WEATHER_TEST_TRIGGER) PYTHONPATH=src uv run --group dev python -m wilted.cli

install-launchd:
	@# launchd opens StandardOut/ErrorPath at load and will NOT create missing parent
	@# dirs, so pre-create the per-agent log dirs before bootstrap. The wrappers'
	@# own `mkdir -p` runs too late for launchd's own std* capture. See HISTORY.md.
	mkdir -p $(HOME)/Library/Logs/homelab/wilted-nightly
	mkdir -p $(HOME)/Library/Logs/homelab/wilted-scheduler
	ln -sf $(CURDIR)/scripts/wilted-nightly.sh $(HOME)/.launchd/scripts/wilted_nightly.sh
	cp scripts/local.wilted-nightly.plist $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist || true
	ln -sf $(CURDIR)/scripts/wilted-scheduler.sh $(HOME)/.launchd/scripts/wilted_scheduler.sh
	cp scripts/local.wilted-scheduler.plist $(HOME)/Library/LaunchAgents/local.wilted-scheduler.plist
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/local.wilted-scheduler.plist || true
	@echo "Installed: wilted nightly at 2:00 AM and hourly scheduler tick via launchd"

uninstall-launchd:
	launchctl bootout gui/$$(id -u)/local.wilted-nightly 2>/dev/null || true
	rm -f $(HOME)/Library/LaunchAgents/local.wilted-nightly.plist
	rm -f $(HOME)/.launchd/scripts/wilted_nightly.sh
	launchctl bootout gui/$$(id -u)/local.wilted-scheduler 2>/dev/null || true
	rm -f $(HOME)/Library/LaunchAgents/local.wilted-scheduler.plist
	rm -f $(HOME)/.launchd/scripts/wilted_scheduler.sh
	@echo "Uninstalled: wilted nightly and scheduler launchd agents"
