# Task 6 Verification Disposition

Date: 2026-08-17  
Status: in progress; Development CloudKit qualification remains

## Verified component evidence

The final authoritative `make validate` exited 0 with Phase 0 (10/10 legs), native (9/9 legs), CloudSync (34), Mac unit (13), iOS unit (19), Mac UI (5), and iOS UI (2). Earlier focused evidence also passed `WiltedKit` (28 XCTest + 18 Swift Testing sync tests), CloudSync (34/34), and `ListenerAppModelTests` (5/5), plus the iOS Development build. These exercise shared record/fixture contracts, deterministic CloudKit mapping and transport, producer publication/reconciliation state, listener persistence/cache/offline playback, native lifecycle wiring, and fixture-backed native journeys; they do not replace the remaining live qualification.

The recurring Mac UI Gatekeeper dialog was traced to unsupported runner signing. `scripts/test-gate.sh` builds the host and runner with an Apple Development identity for the configured `WILTED_DEVELOPMENT_TEAM`, rejects quarantine/Finder metadata, verifies both signatures, and requires the matching authority and team before launch. A later direct unsigned focused run caused another damaged-runner popup and was stopped. The final authoritative signed, metadata-clean runner passed 5/5 without a popup.

The live adapter now bootstraps `WiltedZone` before fetch/send and performs at most one zone-not-found recreation/requeue. Cancellation, account changes, stale bootstrap generations, remote deletion, per-record save/delete failures, completion ordering, multiple sent events, and cancellation/account change after requeue have explicit regression guards.

Independent review returned PASS after those remediation guards were added.

The initial verifier for the account-change recovery patch timed out without producing a report. That attempt remains unavailable evidence. The completed scoped cross-family Google follow-up found no High or Medium issues and one Low brittle source-text UI test finding. The Low is closed: the source-text assertion was removed, a deterministic quarantined Mac fixture was added, and a real UI journey verifies the visible account-review control and recovery. Its initial protected run failed only because the status `Text` exposes its accessibility content as `value`, not `label`; the corrected predicates passed in the final 5/5 Mac UI gate.

## Account-change recovery evidence

Attended pre-fix screenshots captured the live Mac status moving from Cancelled to Quarantined. The root cause was a nil-state CKSyncEngine account event reaching quarantine without an explicit recovery action in the UI. The patch carries typed sign-in, sign-out, or switch transitions without account identifiers; quarantines durable local work; shows “Use Current iCloud Account”; and after explicit review resets account-change quarantine while reusing the current engine. A compatibility-equality defect initially caused typed iOS sign-in and sign-out signals to be ignored; every typed transition now quarantines and the focused iOS listener suite passed 5/5 with a passing Development build.

The accepted race finding showed that a transport completion could arrive after quarantine but before the coordinator committed a fetch or acknowledged a send. `SyncTransport.operationGeneration()` now lets the coordinator reject work superseded by an account change, with deterministic fetch-before-commit and send-before-acknowledgement regressions. Current focused gates passed `WiltedKit` 28 XCTest plus 18 Swift Testing sync tests and CloudSync 34/34.

This is not post-fix live qualification. No attended post-fix Development producer-to-listener round trip has run.

## Attended portal evidence

On 2026-08-17, attended screenshots verified Apple Developer portal configuration for container `iCloud.com.zerodelta.wilted` and App IDs `com.zerodelta.wilted.mac` and `com.zerodelta.wilted.ios`. Both App IDs show iCloud/CloudKit enabled with exactly that container and Push Notifications enabled. This is portal configuration evidence only; it is not provisioning-profile, effective signed-entitlement, or runtime evidence.

During an attended Development run, David observed private zone `WiltedZone` in CloudKit Console. This qualifies only the Development zone-bootstrap result; it does not establish post-fix account-review recovery or any producer-to-listener record transfer.

## Attended Development publication evidence (2026-08-18)

The post-fix attended run established the producer half of the round trip. Two records queued
by the Mac producer, `item:item-d565b326…` and its revision, were published to the private
`WiltedZone` in Development CloudKit. Verified by decoding the persisted repository state in
`~/Library/Application Support/Wilted/library.sqlite` rather than by reading the status
surface: 0 pending changes, 0 conflicted records, both record IDs present in
`remoteAcknowledgedRecordIDs`, an account owner token recorded, and 3584 bytes of CKSyncEngine
state persisted for the first time. The panel reported `Uploaded 2 changes.`

Three defects were found and fixed during this run, each with regression coverage proven by
neutering the fix and observing the new tests fail.

A send withholds conflicted records, so a fully conflicted queue produced an empty batch, a
clean acknowledgement, and a completed status indistinguishable from a real upload. A fully
blocked send now fails closed with a typed error before the transport is contacted, and a
partly blocked send names both what moved and what is still held.

The Mac account-review quarantine was in-memory while the quarantine it represents is durable,
so a relaunched app came back unquarantined, the review control never rendered, and the
persisted conflicts blocked every send for the life of the install.

The blocking defect was a first-sign-in deadlock. A CKSyncEngine built without persisted
serialization always reports a first sign-in, and the gate quarantined every sign-in, so the
first-ever sync quarantined before it could send; no send meant no engine state, and no engine
state meant the next engine reported a first sign-in again. Observed live as fifteen
consecutive polls held at Quarantined after an explicit review. The sign-in is now classified
rather than the gate weakened: the adapter derives a non-reversible token from the event's
current user and compares it to a token persisted with the repository state, so an unclaimed
device adopts the account, a matching owner resumes after engine-state loss, and anything else
still quarantines for review. Sign-out and account switches quarantine unconditionally, and raw
account identifiers still stop at the adapter boundary. The account path had been reachable only
through a live-only cast to the concrete CloudKit transport, which is why every suite stayed
green over a deadlock in the shipping build; it now travels on the injected transport handle and
the unit gate drives it directly.

This is Development producer publication evidence only. It is not listener download, cache,
offline or background playback, playback reconciliation, deletion propagation, physical-device,
Production CloudKit, or TestFlight evidence.

## Boundary and remaining work

Task 6 is not complete. Development publication is now proven (above); the listener half is not.
The remaining blocker is an attended Development download/cache, offline and background playback,
playback reconciliation across relaunch, and deletion propagation on the physical iPhone. The
signed Development listener carrying the deadlock fix is built but not installed: the paired
iPhone's device tunnel was unavailable, so `devicectl device install` failed three times and the
device must be connected and unlocked before the listener half can run. The listener build still
running on that device predates the fix and shares the deadlock, which is the likely source of
its reported refresh failure. Task 7 remains blocked. Apart from the user-observed Development `WiltedZone` bootstrap, this checkpoint provides no live record-operation, post-fix recovery, provisioning-profile or effective signed-entitlement, physical-device, Production CloudKit, App Store Connect processing, or TestFlight evidence.
