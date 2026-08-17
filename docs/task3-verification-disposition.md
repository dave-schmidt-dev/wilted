# Task 3 Verification Disposition

Date: 2026-08-17
Status: verified locally; Task 4 unblocked

## Evidence

The full `make validate` gate passed. Authoritative nonzero legs were: Phase 0 (10), native (6), `WiltedKit` (28), Mac unit (10), iOS unit (14), Mac UI (2), and iOS UI (2). Mac pixel snapshots contain 156 PNG baselines: 19 states x 8 variants plus 4 shell states. XcodeGen generation is reproducible; `project.yml` remains the source of truth, and generated project output is absent/ignored.

The Mac UI runner was ad-hoc signed before launch. The fix covers the three prior Gatekeeper damaged-app dialogs with target signing, a codesign preflight, and regression/meta coverage. iOS UI verification uses a clean simulator lifecycle; stale `kAXErrorAPIDisabled` and accessibility parent-identifier overwrite defects are covered.

`swift-snapshot-testing` 1.19.4 was approved as a test-only MIT dependency, with real pixel baselines. External findings on player routes, baselines, and the root xcodeproj ignore were remediated. The synthetic `NATIVE_SELF_TEST` concern was rejected as a hermetic meta-mode concern: production `make validate` ran the actual legs and counts.

## Boundary

This is local automated and simulator evidence only. It does not establish signed distribution, physical-device behavior, Production CloudKit, App Store Connect processing, or TestFlight availability. Those remain explicit human/release gates.
