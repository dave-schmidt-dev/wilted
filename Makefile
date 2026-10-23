.PHONY: validate validate-inner native-meta native native-mac-unit native-ios-unit native-ui lint deadcode file-size check-fast install-hooks worktree-setup install app-icon ad-corpus ad-corpus-replay ad-corpus-adopt ad-feedback-drafts

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
	@env $(NATIVE_UNIT_FILTER_UNSET) bash scripts/test-gate.sh || echo native-gate >>$(VALIDATE_FAILURES)
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

# The full gate INCLUDING the macos-ui-tests leg. That leg drives real HID
# events through WindowServer and will hold the cursor, keyboard, and window
# focus for its entire run, so it is deliberately absent from `validate` and
# `native`. Run this when you can give up the machine; the deferred-leg line
# in every other run tells you when it is owed.
# A clean, fully green run writes a commit-bound receipt that `make install` checks.
# The receipt runner checks cleanliness before entering the screen-seizing gate.
# `caffeinate` because every test in the leg fails with "Failed to activate
# application (current state: Running Background)" if the display sleeps
# mid-run, which reads as every journey broken rather than one asleep Mac.
native-ui:
	@WILTED_MAC_UI=1 caffeinate -disu python3 scripts/native-ui-receipt.py record

# Regenerates the app icons from the shipping `WiltedMarkShape`, so the icon and
# the in-app mark cannot drift. Rerun after any change to the brand geometry.
app-icon:
	@bash scripts/generate-app-icon.sh

# Builds the Mac app and replaces the locally installed copy in /Applications,
# so the app being daily-driven is the app in the working tree. Development,
# the live build that runs the library publisher against Development CloudKit;
# Debug has no live transport and Release needs a Developer ID identity this
# machine is not required to hold. See the script for the signing and TCC grant.
# Refuses when no green `make native-ui` receipt covers the Mac UI surface being
# installed; WILTED_SKIP_UI_RECEIPT=1 installs anyway with a loud warning.
install:
	@python3 scripts/native-ui-receipt.py check-head
	@bash scripts/install-mac-app.sh

# Scores the ad detector against hand-labelled real episodes, reading the cuts
# each preparation already committed to the library. No model, no network, and
# it answers the question the unit tests cannot: is the episode on this machine
# still wrong? Exits non-zero while any case fails, which is the point.
ad-corpus:
	@python3 Producer/Workers/ad_corpus.py --mode recorded

# Pins the corpus's inputs out of a snapshot of the preparation cache, because
# that cache is a 32-entry LRU working set for preparation and evicts: all
# three original cases' transcripts were evicted from it and the replay then
# measured nothing. Takes the snapshot directory, e.g.
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
# Usage: make ad-feedback-drafts [OUT=<file outside the repo>]
ad-feedback-drafts:
	@python3 Producer/Workers/ad_feedback_export.py $(if $(OUT),--out "$(OUT)")

# The same scoring, but re-running the live detector over the aligned segments
# the original run consumed, so a candidate fix can be measured without
# re-preparing anything. Loads the GGUF model and takes minutes; it takes the
# same GPU admission lock a preparation takes, so running it while the app is
# working queues rather than contends. `--strict` because this is the mode a
# candidate fix is judged in: a case whose input is missing here measured
# nothing, and a corpus that silently shrinks to whatever this machine holds is
# how a fix gets called good. Inputs resolve from the pinned store first (see
# `ad-corpus-adopt`) and the aligned cache only as a fallback. `ad-corpus`
# stays lenient -- it reads
# mutable library state and a machine that has prepared neither episode should
# still be able to run it and read the report.
# The runtime's own interpreter, not the system one, and resolved from the same
# variable Swift resolves it from (see `PodcastPreparationPipeline.Configuration
# .resolved`): the model bindings the detector imports live in that virtualenv
# and nowhere else. Populate it with `make worktree-setup`.
ad-corpus-replay:
	@"$${WILTED_PIPELINE_PYTHON:-$(UV_PROJECT_ENVIRONMENT)/bin/python}" \
		Producer/Workers/ad_corpus.py --mode replay --strict
