# wilted

Local-first native Mac/iOS personal audio system: a Mac producer prepares audio and an iOS listener receives and plays it.

**Status:** Phase 0 through Task 5 are complete; the CloudKit and iOS listener slice is in progress.

Task 6 component gates are green, but the authoritative full gate remains fail-closed: the Mac UI runner builds and passes signature checks, while unattended execution is disabled after repeated Gatekeeper damaged-runner dialogs. Task 6 is not complete.

## Priorities (in order)

1. Native usability.
2. Reliable playback and resume.
3. Privacy and local processing.
4. Verifiable producer-to-listener delivery.

## Scope

The MVP is a native SwiftUI Mac producer and iOS listener. The Mac accepts an article URL, prepares cancellable audio with visible progress, maintains a local library and durable resume, and publishes immutable audio revisions to the user's private CloudKit database. iOS downloads and caches those revisions for offline/background playback and reports playback state back.

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

Phase 0 contract freeze and Tasks 3–5 are complete. Task 6 remains in progress; MVP qualification remains blocked. `make validate` is the authoritative local gate and is currently expected to fail closed at guarded Mac UI execution, not pass. XcodeGen `project.yml` remains authoritative and generated project output is absent/ignored. Follow `INVARIANTS.md` and keep local, Development CloudKit, signed Production, physical-device, App Store Connect, and TestFlight evidence distinct. See [`docs/phase0-decision-record.md`](docs/phase0-decision-record.md), [`docs/phase0-verification-disposition.md`](docs/phase0-verification-disposition.md), [`docs/task3-verification-disposition.md`](docs/task3-verification-disposition.md), [`docs/task4-verification-disposition.md`](docs/task4-verification-disposition.md), the attended [`docs/task5-cloudkit-capability-preflight.md`](docs/task5-cloudkit-capability-preflight.md), [`docs/task5-verification-disposition.md`](docs/task5-verification-disposition.md), and [`docs/task6-verification-disposition.md`](docs/task6-verification-disposition.md).

## Conventions

- Keep all project files self-contained under this directory; do not depend on `wilted-old` at runtime.
- Secrets belong in BWS and never in committed files.
- UI code does not write producer state directly; shared domain contracts own identity, transfer, and playback reconciliation.
- Native UI follows the canonical Zero Delta structure with Wilted's restrained lettuce identity; use literal navigation labels and reserve semantic colors for state.
- Update `HISTORY.md` alongside meaningful changes and keep pending work in `TASKS.md`.
- `HISTORY.md` and `TASKS.md` are local operational documents and are ignored by Git.
