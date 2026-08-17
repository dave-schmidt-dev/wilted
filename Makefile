.PHONY: validate native-meta native

validate:
	@bash tests/test-phase0-aggregate.sh
	@bash scripts/test-phase0.sh
	@bash tests/test-native-gate.sh
	@bash scripts/test-gate.sh

native-meta:
	@bash tests/test-native-gate.sh

native:
	@bash scripts/test-gate.sh
