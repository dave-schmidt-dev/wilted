# wilted

Local-first native Mac/iOS personal audio system: the Mac is the daily-use producer and player, while the deferred iOS listener receives and plays qualified media.

**Status:** Native Mac daily-driver parity is the active milestone. Podcast feed import, local episode download, a mixed Larder, Up Next, continuous playback, direct seeking, and persistent playback speed must reach Phase 3 Mac owner acceptance before any fresh iPhone/CloudKit qualification. Physical-device, Production CloudKit, App Store Connect, and TestFlight qualification remain pending.

On 2026-08-17, attended screenshots verified the Wilted iCloud container and both App IDs with iCloud/CloudKit and Push Notifications enabled. This is Apple Developer portal configuration evidence only. The attended Development producer-to-listener round trip it was waiting on completed on 2026-08-18.

The release gate uses seven non-UI regression legs: `xcodegen-reproducible`, `wiltedkit-tests`, `cloudsync-tests`, `listener-tests`, `wiltedproducer-tests`, `macos-unit-tests`, and `ios-unit-tests`, plus two UI legs: `macos-ui-tests`, which drives the shipping Mac window, and one clean-simulator iOS UI leg covering ten pixel baselines and the account-free MVP journey. The Mac UI leg was silently dropped from the run list on 2026-08-23 and restored on 2026-08-25; `tests/test-native-gate.sh` now asserts that it is invoked, not merely defined. Every leg is backed by Xcode or SwiftPM result evidence. The Phase 0 run also proves its own harness: one leg is forced to fail before the real pass, so a gate that cannot see a failure fails itself.

The attended Development CloudKit round trip completed on 2026-08-18 on a physical iPhone 16 Pro Max, and its evidence is read from the device's own persisted state rather than from an on-screen status: three records (`WiltedItem`, `WiltedRevision`, `WiltedPlaybackState`) each carrying server system fields and a change tag, all three acknowledged by the private zone, zero pending changes, zero conflicts, and an account owner token equal to the Mac producer's. The publish, download, offline play, send, and relaunch-reconcile legs each ran, and on 2026-08-18 they ran as one composed pass from a freshly installed app with an empty data container, so the download and first-sign-in owner-token adoption were genuinely exercised rather than inherited from a warm cache. Background playback is real: with the position zeroed first, a 25.17 s background hold leaves the engine at 27.0 s, reproduced across four consecutive runs, and a foreground hold of the same length gives 25.0 s. The journey that measures it is not yet reliable, though -- it intermittently reports 0.0 s at other hold lengths, which is a test race rather than a playback failure but is not yet eliminated, so treat the background leg as demonstrated rather than gated. Playback is served from the local cache, and no airplane-mode run was performed, so this is cache-backed rather than a proven radio-off journey.

Pre-fix attended screenshots captured a live account-change transition from Cancelled to Quarantined. The recovery patch preserves every typed sign-in, sign-out, or switch transition, quarantines local work, exposes explicit review before reusing the current engine, and rejects fetch/send completions superseded by an account change. The scoped cross-family Google follow-up found no High or Medium issues. Its accepted Low brittle source-text UI assertion is closed: a deterministic quarantined fixture now drives a real Mac UI recovery-control journey. The post-fix live round trip has since run and is described above.

The CloudKit Console now shows private zone `WiltedZone` after an attended Development run. This is user-observed zone-bootstrap evidence only, not proof of post-fix account recovery or a producer-to-listener record round trip.

On 2026-08-18 an attended Development run published and reconciled the producer-to-listener round trip on the paired iPhone, including listener download, cached playback, playback-state acknowledgement, and relaunch reconciliation. That evidence is historical Development/device evidence only; the current source still requires fresh physical-device and Production CloudKit qualification before any App Store Connect or TestFlight claim.

## Priorities (in order)

1. Native usability.
2. Reliable playback and resume.
3. Privacy and local processing.
4. Verifiable producer-to-listener delivery.

## Scope

The active milestone turns the native SwiftUI Mac app into a daily driver. The existing article path stays intact; the milestone adds subscribed podcast feeds, cancellable local episode downloads with visible progress, atomic enclosure imports, a mixed Larder, durable Up Next, continuous playback, direct seeking, persistent speed, and exact resume. Podcast feeds, episodes, queue state, playback speed, and episode checkpoints remain local-only until Phase 3 Mac owner acceptance. The existing iOS listener and article CloudKit path remain unchanged while that Mac milestone is implemented and qualified.

Navigation is a destination switch on both platforms. The Mac window is a two-column split view whose sidebar lists Larder, Prep, and Settings; Now Playing is an always-visible bottom rail, with Transcript and Up Next inline in that rail, and playback survives switching destinations. iPhone exposes Larder, Now Playing, and Settings as tabs; download state and controls live in Larder rather than a duplicate Downloads tab. The candidate-current Mac route inventory is the self-contained [`docs/2026-08-31-mac-daily-driver-walkthrough.html`](docs/2026-08-31-mac-daily-driver-walkthrough.html); it is evidence in progress and does not claim owner acceptance.

The former `wilted-old` directory is reference-only and non-runnable. Its absolute paths, legacy runtime bindings, SQLite data, alias, virtual environment, and retired launchd jobs are intentionally archived. On 2026-08-17, the owner approved transferring the existing GitHub repository to this fresh project; the old Git history was not migrated, and the local archive remains the recovery copy. Retired nightly/hourly scheduling is disabled. The current `wilted` shell alias is stale and must not be treated as an installation.

Explicitly excluded from the active Mac milestone: automatic classification, ad stripping, weather, radio mode, dynamic playlists, email, social drafting, background scheduling, and TUI/CLI parity.

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

Phase 0 contract freeze and the earlier Tasks 3–6 implementation work are complete. The current sequence is Mac-first: implement and qualify the native Mac daily-driver milestone, obtain Phase 3 Mac owner acceptance, and only then begin Task 7's fresh iPhone/CloudKit qualification. `make validate` is the authoritative local gate, with one deliberate hole: it defers the `macos-ui-tests` leg, which drives real HID events through WindowServer and takes over the cursor, keyboard, and window focus for its whole run. `make native-ui` runs the gate including that leg. A deferred run says so by name in `native.deferred` and never claims an unqualified pass, so the debt is always visible; see `INVARIANTS.md` for what that changes about the charter. Mac UI execution requires an installed Apple Development identity for the configured `WILTED_DEVELOPMENT_TEAM` and fails closed before launch if the host or runner identity differs. XcodeGen `project.yml` remains authoritative and generated project output is absent/ignored. Follow `INVARIANTS.md` and keep local Mac owner acceptance, portal configuration, effective signed entitlements, Development CloudKit runtime, Production CloudKit, physical-device, App Store Connect, and TestFlight evidence distinct. See [`docs/phase0-decision-record.md`](docs/phase0-decision-record.md), [`docs/phase0-verification-disposition.md`](docs/phase0-verification-disposition.md), [`docs/task3-verification-disposition.md`](docs/task3-verification-disposition.md), [`docs/task4-verification-disposition.md`](docs/task4-verification-disposition.md), the attended [`docs/task5-cloudkit-capability-preflight.md`](docs/task5-cloudkit-capability-preflight.md), [`docs/task5-verification-disposition.md`](docs/task5-verification-disposition.md), and [`docs/task6-verification-disposition.md`](docs/task6-verification-disposition.md).

## Conventions

- Keep all project files self-contained under this directory; do not depend on `wilted-old` at runtime.
- Secrets belong in BWS and never in committed files.
- UI code does not write producer state directly; shared domain contracts own identity, transfer, and playback reconciliation.
- Native UI follows the canonical Zero Delta structure with Wilted's restrained lettuce identity; use literal navigation labels and reserve semantic colors for state.
- Update `HISTORY.md` alongside meaningful changes and keep pending work in `TASKS.md`.
- `HISTORY.md` and `TASKS.md` are local operational documents and are ignored by Git.
