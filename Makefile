.PHONY: validate native-meta native native-ui app-icon

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
native-ui:
	@WILTED_MAC_UI=1 bash scripts/test-gate.sh

# Regenerates the app icons from the shipping `WiltedMarkShape`, so the icon and
# the in-app mark cannot drift. Rerun after any change to the brand geometry.
app-icon:
	@bash scripts/generate-app-icon.sh
