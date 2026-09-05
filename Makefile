.PHONY: validate native-meta native native-ui install app-icon ad-corpus ad-corpus-replay

validate:
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
# `caffeinate` because every test in the leg fails with "Failed to activate
# application (current state: Running Background)" if the display sleeps
# mid-run, which reads as sixteen broken journeys rather than one asleep Mac.
native-ui:
	@WILTED_MAC_UI=1 caffeinate -disu bash scripts/test-gate.sh

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

# The same scoring, but re-running the live detector over the aligned segments
# the original run consumed, so a candidate fix can be measured without
# re-preparing anything. Loads the GGUF model and takes minutes; it takes the
# same GPU admission lock a preparation takes, so running it while the app is
# working queues rather than contends.
# The archive's interpreter, not the system one, and resolved from the same
# variable Swift resolves it from: the model bindings the detector imports live
# in that virtualenv and nowhere else.
ad-corpus-replay:
	@"$${WILTED_PIPELINE_PYTHON:-$$HOME/Documents/Projects/wilted-old/.venv/bin/python}" \
		Producer/Workers/ad_corpus.py --mode replay
