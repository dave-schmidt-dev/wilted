.PHONY: validate validate-inner native-meta native native-mac-unit native-ios-unit native-ios-appintents-27 native-ui lint deadcode file-size check-fast install-hooks worktree-setup install install-walkthrough app-icon ad-corpus ad-corpus-adopt ad-feedback-drafts ad-feedback-weekly ad-feedback-mark-handled retention-report retention-apply retention-install

# The runtime venv every target shares (Producer/Runtime/Makefile pins the same path).
export UV_PROJECT_ENVIRONMENT := $(CURDIR)/Producer/Runtime/.venv

# Python outside Producer/Runtime is linted by the root ruff.toml.
lint:
	@$(MAKE) -C Producer/Runtime lint
	"$(UV_PROJECT_ENVIRONMENT)/bin/ruff" check Producer/Workers/wilted_worker scripts app tests

deadcode:
	@$(MAKE) -C Producer/Runtime deadcode

file-size:
	@python3 scripts/check_file_size.py --staged

check-fast: file-size lint deadcode
	@python3 scripts/test-settings-section-inventory.py
	@python3 scripts/check-no-global-tmp.py

install-hooks:
	@$(MAKE) -C Producer/Runtime install-hooks

# Provisions this checkout for the gates: links the sibling projects the runtime
# lock and the release wrappers resolve beside a linked worktree, syncs
# Producer/Runtime/.venv from uv.lock, and proves the speech stack's GPU lock is
# the shared canonical one. Idempotent; run once in each new worktree.
worktree-setup:
	@bash scripts/worktree-setup.sh

validate:
	@bash -c 'source scripts/lib/test-temp-state.sh; WILTED_TEMP_LEAK_CHECKER="$(CURDIR)/scripts/check-temp-leaks.py"; wilted_full_run "$(CURDIR)" $(MAKE) validate-inner'

# Unit selector and iteration variables are diagnostics: keep them out of every
# meta-test and the pre-push gate that validate-inner runs.
NATIVE_UNIT_FILTER_UNSET = -u WILTED_MAC_UNIT_SELECTORS -u WILTED_MAC_UNIT_ITERATIONS -u WILTED_IOS_UNIT_SELECTORS -u WILTED_IOS_UNIT_ITERATIONS

# A failing step never stops the gate: every step runs, each failure is noted in
# one file, and the last line reports them all together and fails. Each recipe
# line is its own shell whose parent is this make, so $$PPID names one file per run.
VALIDATE_FAILURES = "$${TMPDIR:?}/wilted-validate-failures.$$PPID"

validate-inner:
	@rm -f $(VALIDATE_FAILURES)
	@python3 scripts/check-no-global-tmp.py || echo check-no-global-tmp >>$(VALIDATE_FAILURES)
	@python3 scripts/check_file_size.py --all || echo check-file-size >>$(VALIDATE_FAILURES)
	@env -u WILTED_GATE_LEGS -u WILTED_NATIVE_RESULTS_DIR $(NATIVE_UNIT_FILTER_UNSET) bash tests/test-phase0-aggregate.sh || echo test-phase0-aggregate >>$(VALIDATE_FAILURES)
	@env -u WILTED_GATE_LEGS -u WILTED_NATIVE_RESULTS_DIR $(NATIVE_UNIT_FILTER_UNSET) bash scripts/test-phase0.sh || echo phase0 >>$(VALIDATE_FAILURES)
	@env -u WILTED_GATE_LEGS -u WILTED_NATIVE_RESULTS_DIR $(NATIVE_UNIT_FILTER_UNSET) bash tests/test-native-gate.sh || echo test-native-gate >>$(VALIDATE_FAILURES)
	@env -u WILTED_GATE_LEGS -u WILTED_NATIVE_RESULTS_DIR $(NATIVE_UNIT_FILTER_UNSET) bash tests/test-native-gate-watch.sh || echo test-native-gate-watch >>$(VALIDATE_FAILURES)
	@env -u WILTED_GATE_LEGS -u WILTED_NATIVE_RESULTS_DIR $(NATIVE_UNIT_FILTER_UNSET) bash tests/test-carplay-config.sh || echo test-carplay-config >>$(VALIDATE_FAILURES)
	@env $(NATIVE_UNIT_FILTER_UNSET) bash scripts/verify-once-gate.sh headless || echo native-gate >>$(VALIDATE_FAILURES)
	@if [ -s $(VALIDATE_FAILURES) ]; then printf 'validate.failed count=%s steps=%s\n' "$$(wc -l <$(VALIDATE_FAILURES) | tr -d ' ')" "$$(tr '\n' ' ' <$(VALIDATE_FAILURES))" >&2; rm -f $(VALIDATE_FAILURES); exit 1; fi; rm -f $(VALIDATE_FAILURES); printf '%s\n' 'validate.passed' >&2

native-meta:
	@bash tests/test-native-gate.sh

native:
	@bash scripts/test-gate.sh

# Runs one Mac unit test class or method N times through the native gate.
# Usage: make native-mac-unit TEST=WiltedMacFooTests/testBar ITERATIONS=5
# TEST and ITERATIONS reach the recipe through the environment, never through
# make text expansion, so the gate's validation sees the value unquoted.
native-mac-unit:
	@test -n "$${TEST-}" || { printf '%s\n' 'usage: make native-mac-unit TEST=<Class[/testMethod],...> [ITERATIONS=<n>]' >&2; exit 2; }
	@if [ -n "$${ITERATIONS-}" ]; then export WILTED_MAC_UNIT_ITERATIONS="$$ITERATIONS"; fi; WILTED_GATE_LEGS=macos-unit-tests WILTED_MAC_UNIT_SELECTORS="$$TEST" bash scripts/test-gate.sh

# Runs one iOS unit test class or method N times through the native gate.
# Usage: make native-ios-unit TEST=WiltediOSFooTests/testBar ITERATIONS=5
native-ios-unit:
	@test -n "$${TEST-}" || { printf '%s\n' 'usage: make native-ios-unit TEST=<Class[/testMethod],...> [ITERATIONS=<n>]' >&2; exit 2; }
	@if [ -n "$${ITERATIONS-}" ]; then export WILTED_IOS_UNIT_ITERATIONS="$$ITERATIONS"; fi; WILTED_GATE_LEGS=ios-unit-tests WILTED_IOS_UNIT_SELECTORS="$$TEST" bash scripts/test-gate.sh

# Runs only the five iOS 27 App Intents system-runner selectors. This filtered
# diagnostic is never a release receipt; the verify-once gate records the full leg.
native-ios-appintents-27:
	@WILTED_GATE_LEGS=ios27-appintents-tests bash scripts/test-gate.sh

# The screen-seizing macos-ui-tests leg, run once and recorded as a verify-once
# receipt for this source (what `make install` and the TestFlight upload check).
# That leg drives real HID events through WindowServer and will hold the cursor,
# keyboard, and window focus for its entire run, so it is deliberately absent from
# `validate` and `native`. Run this when you can give up the machine; the deferred-leg
# line in every other run tells you when it is owed. Inside a release, the same leg
# runs through app/verify-release-ui on the staged candidate.
# `caffeinate` (inside the script) because every test in the leg fails with "Failed to
# activate application (current state: Running Background)" if the display sleeps
# mid-run, which reads as every journey broken rather than one asleep Mac.
native-ui:
	@bash scripts/verify-once-gate.sh ui-verify

# Regenerates the app icons from the shipping `WiltedMarkShape`, so the icon and
# the in-app mark cannot drift. Rerun after any change to the brand geometry.
app-icon:
	@bash scripts/generate-app-icon.sh

# Builds the Mac app and replaces the locally installed copy in /Applications,
# so the app being daily-driven is the app in the working tree. Development,
# the live build that runs the library publisher against Development CloudKit;
# Debug has no live transport and Release needs a Developer ID identity this
# machine is not required to hold. See the script for the signing and TCC grant.
# Refuses when no fresh `make native-ui` receipt covers this source;
# WILTED_SKIP_UI_RECEIPT=1 installs anyway with a loud warning.
install:
	@bash scripts/verify-once-gate.sh check-ui
	@bash scripts/install-mac-app.sh

# The walkthrough build: the same install after the headless gate alone. A
# release walkthrough has to run on the new build, and the screen-seizing leg
# runs once, after that walkthrough, on the final candidate while David is
# away, so `install`'s receipt check cannot come first. Everything `validate`
# runs must pass; nothing records a ui receipt, and `install` still refuses
# this source until `make native-ui` has run on it.
install-walkthrough:
	@$(MAKE) validate
	@bash scripts/install-mac-app.sh

# Scores the ad detector against hand-labelled real episodes, reading the cuts
# each preparation already committed to the library. No model, no network, and
# it answers the question the unit tests cannot: is the episode on this machine
# still wrong? Exits non-zero while any case fails, which is the point.
ad-corpus:
	@python3 Producer/Workers/ad_corpus.py --mode recorded

# Pins the corpus's inputs out of a snapshot of the preparation cache, because
# that cache is a 32-entry LRU working set for preparation and evicts, and a case whose
# input is gone measures nothing. Takes the snapshot directory, e.g.
# `make ad-corpus-adopt SOURCE=~/Library/Application\ Support/Wilted/adcorpus-snapshot-2026-09-17`. Copies only entries
# a manifest case names into ~/Library/Application Support/Wilted/adcorpus-inputs/,
# reports each by case id, and exits non-zero when the snapshot cannot satisfy
# a case. Nothing is copied into the repository: transcripts are third-party
# copyrighted content and this repository is public.
ad-corpus-adopt:
	@test -n "$(SOURCE)" || { printf '%s\n' 'usage: make ad-corpus-adopt SOURCE=<cache snapshot directory>'; exit 2; }
	@python3 Producer/Workers/ad_corpus.py --adopt "$(SOURCE)"

# Turns the ad feedback accepted in Settings > Ad feedback into draft corpus
# cases and labels for adcorpus/manifest.json. Drafts name shows, so OUT must
# be outside the repository; without OUT they print to stdout.
# Usage: make ad-feedback-drafts [FEEDBACK=<snapshot.json>] [OUT=<file outside the repo>]
ad-feedback-drafts:
	@python3 Producer/Workers/ad_feedback_export.py $(if $(FEEDBACK),--feedback "$(FEEDBACK)") $(if $(LIBRARY),--library "$(LIBRARY)") $(if $(MANIFEST),--manifest "$(MANIFEST)") $(if $(OUT),--out "$(OUT)")

# Capture a private weekly inbox snapshot and identity-aware report. Reads the
# app-owned inbox but never edits it, marks reports, queues an app action, or runs a model.
# Usage: make ad-feedback-weekly [FEEDBACK=<inbox.json>] [RUNS_ROOT=<private directory>] [HISTORY_ROOT=<logs directory>] [WEEK_START=<Monday YYYY-MM-DD>]
ad-feedback-weekly:
	@python3 Producer/Workers/ad_feedback_weekly.py $(if $(FEEDBACK),--feedback "$(FEEDBACK)") $(if $(RUNS_ROOT),--runs-root "$(RUNS_ROOT)") $(if $(HISTORY_ROOT),--history-root "$(HISTORY_ROOT)") $(if $(WEEK_START),--week-start "$(WEEK_START)")

# Queue validated tuning evidence for the app-owned ad-feedback store to apply.
# The command reads the inbox and library, writes only Wilted's private queue,
# then wakes the app with a fixed URL that carries no report or file data.
# Usage: make ad-feedback-mark-handled PROOF=<proof.json> SNAPSHOT=<intake.json> REPLAY=<replay.json>
ad-feedback-mark-handled:
	@test -n "$(PROOF)" || { printf '%s\n' 'usage: make ad-feedback-mark-handled PROOF=<proof.json> SNAPSHOT=<intake.json> REPLAY=<replay.json>'; exit 2; }
	@test -n "$(SNAPSHOT)" || { printf '%s\n' 'usage: make ad-feedback-mark-handled PROOF=<proof.json> SNAPSHOT=<intake.json> REPLAY=<replay.json>'; exit 2; }
	@test -n "$(REPLAY)" || { printf '%s\n' 'usage: make ad-feedback-mark-handled PROOF=<proof.json> SNAPSHOT=<intake.json> REPLAY=<replay.json>'; exit 2; }
	@python3 Producer/Workers/ad_feedback_handle.py --proof "$(PROOF)" --snapshot "$(SNAPSHOT)" --replay-report "$(REPLAY)" $(if $(FEEDBACK),--feedback "$(FEEDBACK)") $(if $(MANIFEST),--manifest "$(MANIFEST)") $(if $(LIBRARY),--library "$(LIBRARY)") $(if $(REPO),--repo "$(REPO)")

retention-report:
	@python3 scripts/storage-retention.py --repo "$(CURDIR)"

retention-apply:
	@python3 scripts/storage-retention.py --apply --repo "$(CURDIR)"

retention-install:
	@python3 scripts/install-storage-retention.py --repo "$(CURDIR)" --apply --activate
