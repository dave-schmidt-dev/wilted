# Contract fixtures

These JSON files are the executable, platform-neutral contract for the first
Wilted native implementation. Each file contains one readable case and an
`operation` dispatched by `scripts/validate-contract-fixtures.swift`.

Fixture envelope version `1` requires:

- `fixtureVersion`, `caseID`, `operation`, `description`, `input`, and `expected`;
- stable non-empty item, revision, session, and device identifiers where used;
- UTC ISO 8601 timestamps ending in `Z`;
- explicit expected decisions rather than undocumented sample data.

The validator covers publish/decode, revision supersession, offline/delayed
state, schema compatibility, atomic preparation failure, and timeout terminal
errors. Playback adoption across devices is not a fixture operation: its rules
are `merge.rules` in `contracts/domain/schema.json`, tested in
`Producer/Tests/WiltedProducerTests/RemotePositionRulesTests.swift`. Add new
cases as separate files and teach the validator to execute their operation;
unknown operations fail closed.

Run:

```sh
swift scripts/validate-contract-fixtures.swift contracts/fixtures
bash tests/test-contract-fixtures.sh
```
