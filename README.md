# wilted

Local-first native Mac/iOS personal audio system: a Mac producer prepares audio and an iOS listener receives and plays it.

**Status:** Phase 0 through Task 6 are complete; MVP qualification is next.

On 2026-08-17, attended screenshots verified the Wilted iCloud container and both App IDs with iCloud/CloudKit and Push Notifications enabled. This is Apple Developer portal configuration evidence only. The attended Development producer-to-listener round trip it was waiting on completed on 2026-08-18.

The release gate uses seven non-UI regression legs: `xcodegen-reproducible`, `wiltedkit-tests`, `cloudsync-tests`, `listener-tests`, `wiltedproducer-tests`, `macos-unit-tests`, and `ios-unit-tests`. It verifies snapshot baselines and Xcode result bundles without launching either app or taking over the desktop. The Phase 0 run also proves its own harness: one leg is forced to fail before the real pass, so a gate that cannot see a failure fails itself.

The attended Development CloudKit round trip completed on 2026-08-18 on a physical iPhone 16 Pro Max, and its evidence is read from the device's own persisted state rather than from an on-screen status: three records (`WiltedItem`, `WiltedRevision`, `WiltedPlaybackState`) each carrying server system fields and a change tag, all three acknowledged by the private zone, zero pending changes, zero conflicts, and an account owner token equal to the Mac producer's. The publish, download, offline play, send, and relaunch-reconcile legs each ran, and on 2026-08-18 they ran as one composed pass from a freshly installed app with an empty data container, so the download and first-sign-in owner-token adoption were genuinely exercised rather than inherited from a warm cache. Background playback is real: with the position zeroed first, a 25.17 s background hold leaves the engine at 27.0 s, reproduced across four consecutive runs, and a foreground hold of the same length gives 25.0 s. The journey that measures it is not yet reliable, though -- it intermittently reports 0.0 s at other hold lengths, which is a test race rather than a playback failure but is not yet eliminated, so treat the background leg as demonstrated rather than gated. Playback is served from the local cache, and no airplane-mode run was performed, so this is cache-backed rather than a proven radio-off journey.

Pre-fix attended screenshots captured a live account-change transition from Cancelled to Quarantined. The recovery patch preserves every typed sign-in, sign-out, or switch transition, quarantines local work, exposes explicit review before reusing the current engine, and rejects fetch/send completions superseded by an account change. The scoped cross-family Google follow-up found no High or Medium issues. Its accepted Low brittle source-text UI assertion is closed: a deterministic quarantined fixture now drives a real Mac UI recovery-control journey. The post-fix live round trip has since run and is described above.

The CloudKit Console now shows private zone `WiltedZone` after an attended Development run. This is user-observed zone-bootstrap evidence only, not proof of post-fix account recovery or a producer-to-listener record round trip.

On 2026-08-18 an attended Development run published the producer half of the round trip: two queued records reached the private zone, verified by decoding the persisted repository state rather than by reading the status surface. Three defects were found and fixed during that run, including a first-sign-in deadlock in which a sync engine with no persisted state always reported a sign-in, the gate quarantined every sign-in, and the first sync could therefore never send the state that would have prevented the next one. Listener download, playback, reconciliation, and deletion remain unproven; the fixed listener build is not yet installed on the paired iPhone.

## Priorities (in order)

1. Native usability.
2. Reliable playback and resume.
3. Privacy and local processing.
4. Verifiable producer-to-listener delivery.

## Scope

The MVP is a native SwiftUI Mac producer and iOS listener. The Mac accepts an article URL, prepares cancellable audio with visible progress, maintains a local library and durable resume, and automatically publishes immutable revision metadata plus verified byte chunks to the user's private CloudKit database. iOS discovers that catalog automatically, fetches audio only after an explicit Download, reconstructs the original M4A atomically, and caches it for offline/background playback before reporting playback state back.

The former `wilted-old` directory is reference-only and non-runnable. Its absolute paths, legacy runtime bindings, SQLite data, alias, virtual environment, and retired launchd jobs are intentionally archived. On 2026-08-17, the owner approved transferring the existing GitHub repository to this fresh project; the old Git history was not migrated, and the local archive remains the recovery copy. Retired nightly/hourly scheduling is disabled. The current `wilted` shell alias is stale and must not be treated as an installation.

Explicitly excluded from the MVP: RSS discovery, automatic classification, podcast/ad stripping, weather, radio mode, dynamic playlists, email, social drafting, background scheduling, and TUI/CLI parity.

## Layout

| Path | Purpose |
|---|---|
| `README.md` | Purpose, scope, priorities, and project conventions. |
| `INVARIANTS.md` | Native producer/listener and delivery system contract. |
| `HISTORY.md` | Meaningful changes, reset evidence, and archived-path notes. |
| `TASKS.md` | Pending implementation and qualification queue. |
| `LICENSE` | MIT license. |
| `contracts/` | Domain, CloudKit, and audio contracts with checked-in fixtures and evidence. |
| `Probes/` | Credential-free speech, extraction, persistence, audio, and signed-runtime probes. |
| `scripts/` | Contract validators and phase gates. |
| `tests/` | Probe and aggregate gate runners. |
| `docs/` | Capability inventory and phase/task verification records. |
| `WiltedKit/` | CloudKit-free shared Swift domain package and tests. |
| `CloudSync/` | CloudKit adapter, transport, mapping, and deterministic tests. |
| `Listener/` | Local iOS listener repository, cache, playback, and tests. |
| `WiltedMac/`, `WiltediOS/` | Native Mac producer and iOS listener targets. |
| `WiltedMacTests/`, `WiltedMacUITests/`, `WiltediOSTests/`, `WiltediOSUITests/` | Unit, pixel-snapshot, and UI regression coverage. |

## Planning artifacts

The detailed implementation plans are maintained locally outside this public repository. Checked-in decision, capability, and verification records under `docs/` preserve the public evidence boundary.

## Workflows

Phase 0 contract freeze and Tasks 3–6 implementation work are complete. Task 7 MVP qualification remains pending. `make validate` is the authoritative local gate. Mac UI execution requires an installed Apple Development identity for the configured `WILTED_DEVELOPMENT_TEAM` and fails closed before launch if the host or runner identity differs. XcodeGen `project.yml` remains authoritative and generated project output is absent/ignored. Follow `INVARIANTS.md` and keep portal configuration, effective signed entitlements, Development CloudKit runtime, Production CloudKit, physical-device, App Store Connect, and TestFlight evidence distinct. See [`docs/phase0-decision-record.md`](docs/phase0-decision-record.md), [`docs/phase0-verification-disposition.md`](docs/phase0-verification-disposition.md), [`docs/task3-verification-disposition.md`](docs/task3-verification-disposition.md), [`docs/task4-verification-disposition.md`](docs/task4-verification-disposition.md), the attended [`docs/task5-cloudkit-capability-preflight.md`](docs/task5-cloudkit-capability-preflight.md), [`docs/task5-verification-disposition.md`](docs/task5-verification-disposition.md), and [`docs/task6-verification-disposition.md`](docs/task6-verification-disposition.md).

## Conventions

- Keep all project files self-contained under this directory; do not depend on `wilted-old` at runtime.
- Secrets belong in BWS and never in committed files.
- UI code does not write producer state directly; shared domain contracts own identity, transfer, and playback reconciliation.
- Native UI follows the canonical Zero Delta structure with Wilted's restrained lettuce identity; use literal navigation labels and reserve semantic colors for state.
- Update `HISTORY.md` alongside meaningful changes and keep pending work in `TASKS.md`.
- `HISTORY.md` and `TASKS.md` are local operational documents and are ignored by Git.
