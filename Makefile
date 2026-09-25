.PHONY: validate native-meta native native-ui lint deadcode file-size check-fast install-hooks install app-icon ad-corpus ad-corpus-replay ad-corpus-adopt

lint:
	@$(MAKE) -C Producer/Runtime lint

deadcode:
	@$(MAKE) -C Producer/Runtime deadcode

file-size:
	@python3 scripts/check_file_size.py --staged

check-fast: file-size lint deadcode

install-hooks:
	@$(MAKE) -C Producer/Runtime install-hooks

validate:
	@python3 scripts/check_file_size.py --all
	@bash tests/test-phase0-aggregate.sh
	@bash scripts/test-phase0.sh
	@bash tests/test-native-gate.sh
	@bash scripts/test-gate.sh

native-meta:
	@bash tests/test-native-gate.sh

native:
	@bash scripts/test-gate.sh

# The full gate INCLUDING the macos-ui-tests leg. That leg drives real HID
# events through WindowServer and will hold the cursor, keyboard, and window
# focus for its entire run, so it is deliberately absent from `validate` and
# `native`. Run this when you can give up the machine; the deferred-leg line
# in every other run tells you when it is owed.
# A clean, fully green run writes a commit-bound receipt for the pre-push hook.
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
# so the app being daily-driven is the app in the working tree. Debug, because
# Release needs a Developer ID identity and profile this machine is not
# required to hold; see the script for why that also protects the TCC grant.
install:
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
# and nowhere else. Populate it with `uv sync --project Producer/Runtime --locked`.
ad-corpus-replay:
	@"$${WILTED_PIPELINE_PYTHON:-Producer/Runtime/.venv/bin/python}" \
		Producer/Workers/ad_corpus.py --mode replay --strict
