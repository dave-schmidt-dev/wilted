# Task 6 Verification Disposition

Date: 2026-08-17  
Status: in progress; Development CloudKit qualification remains

## Verified component evidence

The authoritative `make validate` passed Phase 0 (10/10) and native (9/9), including `WiltedKit` (28 XCTest + 16 Swift Testing), CloudSync (32/32), Listener (15), Producer (44 XCTest + 12 Swift Testing), Mac unit (12), iOS unit (18), Mac UI (4), and iOS UI (2). CloudSync also built for arm64 iOS 17. These exercise shared record/fixture contracts, deterministic CloudKit mapping and transport, producer publication/reconciliation state, listener persistence/cache/offline playback, native lifecycle wiring, and fixture-backed native journeys. The focused `ListenerAppModelTests` suite also passed 4/4, including the account-reset conflict regression.

The recurring Mac UI Gatekeeper dialog was traced to ad-hoc host and runner signatures. `scripts/test-gate.sh` now builds both with an Apple Development identity for the configured `WILTED_DEVELOPMENT_TEAM`, rejects quarantine/Finder metadata, verifies both signatures, and requires the matching Apple Development authority and team before launch. On 2026-08-17 the attended suite passed 4/4 without a damaged-runner dialog. An earlier aggregate attempt passed 3/4 because XCUITest treated an unrelated foreground Gradus window as an interruption; the affected journey passed on focused retry and the final aggregate rerun passed 4/4.

The live adapter now bootstraps `WiltedZone` before fetch/send and performs at most one zone-not-found recreation/requeue. Cancellation, account changes, stale bootstrap generations, remote deletion, per-record save/delete failures, completion ordering, multiple sent events, and cancellation/account change after requeue have explicit regression guards.

Independent review returned PASS after those remediation guards were added.

## Attended portal evidence

On 2026-08-17, attended screenshots verified Apple Developer portal configuration for container `iCloud.com.zerodelta.wilted` and App IDs `com.zerodelta.wilted.mac` and `com.zerodelta.wilted.ios`. Both App IDs show iCloud/CloudKit enabled with exactly that container and Push Notifications enabled. This is portal configuration evidence only; it is not provisioning-profile, effective signed-entitlement, or runtime evidence.

## Boundary and remaining work

Task 6 is not complete. It still requires an attended real Development CloudKit producer-to-listener round trip, including publication, download/cache, offline/background playback, playback reconciliation, relaunch, deletion, and account-change behavior. Task 7 remains blocked. This checkpoint provides no live CloudKit request, schema creation or inspection, provisioning-profile or effective signed-entitlement proof, physical-device behavior, Production CloudKit, App Store Connect processing, or TestFlight availability.
