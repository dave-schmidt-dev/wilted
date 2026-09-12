# Episode state model and transition ownership — plan for issue #1

Review basis: `2d7747282eb2f8d8523399346d9ba9a53d52a1fb`. Every line reference below was read at that commit. The working tree at time of writing carries uncommitted modifications to `LocalLibraryStore.swift`, `PodcastDownloadCoordinator.swift`, `PodcastPreparationPipeline.swift`, `WiltedMacModel.swift`, and their tests; the implementer must rebase this plan onto whatever those changes land as, and re-verify the line anchors before editing.

## Outcome

Episode state stops being a single narrative and becomes five independent durable facts, each with exactly one authoritative record and one writer. Download result becomes a value that automation can act on instead of a presentation side effect. Successful preparation becomes a transactional row written in the same save as the artifact it describes, so no process-local override is needed to manufacture readiness. Finished listening, Larder retirement, feed dismissal, and media reclamation become four separate operations rather than one destructive cascade whose reach depends on queue layout. Local-media presence becomes a checked dimension instead of an assumption. Pipeline source drift becomes reprocessing eligibility rather than loss of readiness. The Larder reads one batched store snapshot instead of assembling itself from per-episode reads.

No UI label work happens before the state contract lands. The existing display label stays, but it becomes a pure projection of the dimensions rather than a place where state is decided.

## Relationship to the existing deep plan

`docs/2026-09-11-lifecycle-reliability-deep-plan.md` states a "Lifecycle contract" of exactly one of ten values. That is the single lifecycle enum this issue forbids as a *durable model*. The two documents are compatible only under this reading, which this plan adopts: the ten-value contract is the **presentation** contract, computed by `WiltedMacEpisodeLifecyclePresentation` (`WiltedMac/WiltedMacModel.swift:512-585`) from the orthogonal dimensions below; it is never persisted, never the input to a transition, and never the thing a store method branches on. That plan's Phase 1 (durable completion, successor/no-successor symmetry, bounded bootstrap invalidation) overlaps this plan's Phase 5 and Phase 7 directly. **Owner decision required:** whether this plan supersedes that plan's Phase 1 or whether that plan's Phase 1 ships first and this one rebases on it. This document assumes supersession and folds the overlapping work into Phases 5 and 7.

## Facts and boundaries

The typed result contract the issue asks for already exists. `PodcastDownloadCoordinator.download(episodeID:expectedContentHash:ignoringExisting:onStatus:)` (`Producer/Sources/WiltedProducer/PodcastDownloadCoordinator.swift:177-387`) is `async throws -> PodcastDownloadResult`, persists `.cancelled`/`.failed` in its final catch (375-386), and rethrows a typed `PodcastDownloadCoordinatorError`. Nothing in the Producer layer loses the result. The loss is entirely in the Mac model: `downloadEpisode(_:alreadyClaimed:ignoringExisting:)` (`WiltedMac/WiltedMacModel.swift:2005-2118`) catches everything and maps it to `downloadState` plus `podcastOperationMessage`; its task table is `podcastDownloadTasks: [String: Task<Void, Never>]` (line 1174), a type that cannot carry a failure; and `startClaimedDownload(_:)` (1613-1623) awaits that non-throwing task and returns normally. `WiltedAutomationCoordinator.drain(_:)` (`WiltedMac/WiltedAutomationCoordinator.swift:297-315`) then counts a normal return as a completed download, and `withRetries` (321-336, `maximumRetries = 3`, `baseRetryDelay = 2`) never sees the failure. So this is an adapter defect, not a missing Producer contract, and the fix must not disturb the coordinator's existing API.

Preparation has two ordering hazards, not one. The issue names the second: `PodcastPreparationPipeline.prepare(episodeID:policy:onStatus:)` (`Producer/Sources/WiltedProducer/PodcastPreparationPipeline.swift:575-669`) calls `commit(...)` (967-1035), which publishes bytes and calls `store.replaceReadyRevision(...)` in one save, and only afterwards calls `journalTerminal(...)` (687-732), whose final write is `try? await store.record(preparation:)` — best-effort proof of an authoritative fact. The first hazard is earlier and worse: `prepare()` begins with `try? await store.clearPreparationJournal(for: requestID)`, with the code's own comment explaining why: "The journal is one attempt deep. Left in place, the previous attempt's terminal row would report this one as finished before it had started." For an episode that was already prepared, that deletes the only durable proof of the previous success *before any work starts*. If the run then dies, `WiltedMacModel.closeInterruptedPreparationRuns(in:)` (4444-4450) stamps an interrupted `.failed` entry, and `preparationState(run:readyRevisionID:transcript:)` (4807-4832) — which requires a terminal success whose `revisionID` equals the current ready revision — reports Not Prepared over a still-valid artifact. Clearing evidence before producing its replacement is the structural reason the outcome record must be keyed by `(episodeID, revisionID)` and must live outside the one-attempt-deep journal.

Completion is asymmetric by construction. `PlaybackController.handleBackendCompletion(generation:successfully:)` (`Producer/Sources/WiltedProducer/PlaybackController.swift:431-502`) writes `checkpointCompletedRevision()` (504-524) and then either loads `state.nextEpisodeID` inside a `do` block (461-482) or fires `playbackDidFinishHandler?()`. The successor branch never retires anything; `WiltedMacModel.handlePodcastPlaybackFinished()` (4608-4643) does, via `hideEpisode` (2668-2674) then `dismissEpisode` (2683-2701). The successor-load `do` block can throw, which is a second way retirement is skipped. `store.dismissPodcastEpisode(_:at:)` (2762-2797) deletes the episode row plus queue, download, speed, artwork, revision, transcript, and `PlaybackRecord` rows, retaining only the V8 dismissal marker and the preparation journal; it deliberately leaves media bytes because `RevisionID` is content-addressed and two episodes with identical bytes share one revision. `restorePodcastEpisode(_:from:)` (2617-2645) re-upserts the episode row and deletes the marker, so a restored episode is not downloaded and not prepared. Dismissal is therefore destructive and not undoable, and today it is the automatic consequence of finishing an episode with nothing behind it.

Readiness does not check the filesystem. `store.readyRevision(for:revisionID:)` (1597-1607) does a full-table fetch, filters in Swift, and returns a URL without a `stat`. `loadLibrary(from:)` (4679-4768) maps persisted download `.completed` straight to presentation, and `canPlayEpisode` (2989) is `downloadState == .completed && preparationState.isPrepared`. The only existence guard is in `PlaybackController.loadQueuedEpisode(_:playAfterLoad:expectedGeneration:)` (527-560), which throws `.podcastMediaUnavailable` after the user has already pressed play, and does not repair durable state.

Fingerprint invalidation is over-broad by design. `resolvedSemanticFingerprint()` (pipeline 455-536) hashes `semanticVersion = "podcast-preparation-v2"`, the worker file, every `.py` under the Wilted package root, and every source file under `~/Documents/Projects/speech-stack/src/speech_stack`. `store.invalidateStalePodcastPreparations(currentFingerprint:)` (1688-1816) deletes journal rows on *any* difference and writes forced-redownload and reset markers as pseudo-journal entries under the request prefixes `podcast-invalidation|` and `podcast-reset-preparation|`. Because `commit(...)` deletes the original source after publishing, a fingerprint change on a successfully prepared episode can require a fresh network download of an episode whose artifact is perfectly playable. Those marker rows are scheduling state stored in the evidence table, read back through `requiresForcedRedownload(for:)` (1877-1882) and cleared by `markForcedRedownloadCompleted(for:currentFingerprint:)` (1839-1869), whose failure path in the model (2078-2086) surfaces "checkpoint could not be saved" — a third split.

Reconstruction is per-episode. `loadLibrary(from:)` calls `store.podcastEpisodes()` twice (4705, 4723), `store.preparationRuns(limit: Int.max)` once (4719) — which fetches and JSON-decodes every `PreparationRecord` row before grouping by `requestID` (1933-1972) — and then resolves ready revision, playback state, and transcript per episode.

The injection seams for real-wiring tests are half present. `PodcastDownloadCoordinator.init` already takes `transport: any PodcastDownloadTransporting = URLSessionPodcastDownloadTransport()` (coordinator 148-164) and `PodcastPreparationPipeline.init` already takes `runner: any PodcastPipelineRunning = SubprocessPodcastPipelineRunner()` (pipeline 546-562). The gap is that `WiltedMacModel.configureStoreDependencies(_:)` (4499-4508) constructs both with defaults and `WiltedMacModel.init(...)` (1208-1219) exposes no factory for either. Separately, `downloadEpisode` has an entire parallel fixture implementation (2007-2040) that fakes progress and failure without touching the coordinator, so UI-fixture coverage proves nothing about the real path.

Schema baseline: `LocalLibrarySchemaV1` (store 708) through `LocalLibrarySchemaV9` (1126); `LocalLibraryMigrationPlan` (1134-1150) is all `.lightweight` stages V1→V9; `schemaVersion: LocalLibrarySchemaVersion = .current`; a preflight retains a V5 copy at `migrationBackupURL` when `!hasV6PodcastTables(at:)`. Migration fixtures are built programmatically by `createV2MigrationFixture(at:article:playback:)` (1359) and `createV5MigrationFixture(...)` (1372) — there is no on-disk store artifact to maintain.

## The eight planning questions

**1. Which durable record is authoritative for each dimension.** Five dimensions, five records, in the table under "State dimensions". Two records exist today (`PodcastDownloadRecord`, `PodcastEpisodeDismissalRecord`); two are new in V10 (`PodcastPreparationOutcomeRecord`, `PodcastListeningRecord`); one is a new nullable column (`retiredAt` on the episode record). Media availability has no durable record and deliberately gets none: the filesystem is authoritative and the snapshot caches it.

**2. Which transitions must be atomic.** Six boundaries, in "Atomicity boundaries". The two that change: preparation commit must write the outcome row inside the same `save()` as `replaceReadyRevision`, and listening completion must write the listening row inside the same store call as the completed playback checkpoint. Retirement is deliberately *not* atomic with completion — it is a separate, idempotent, second transaction, issued identically on both completion paths, so that a failure to retire never costs the listening fact.

**3. Which state may be ephemeral.** Exactly three things stay in memory: `podcastDownloadTasks` and the running-preparation set (this process's in-flight work, legitimately unknown to the store); `hiddenEpisodeIDs` (optimistic hide, reconciled by the store result on the next snapshot); and `podcastOperationMessage` (transient user-facing text). The `.prepared(summary:)` override at 2374 is removed. `applyingRunningPreparations(to:from:running:)` (~2896-2923) is retained but narrowed to carrying `.preparing` only — never a terminal state. `DeferredAutomaticPreparation` in `UserDefaults` (2133-2177, restored at 2258-2273) is durable state in the wrong store and moves to the library in Phase 8.

**4. How state is reconstructed after relaunch.** One call: `store.podcastLibrarySnapshot()` returns episodes joined against downloads, ready revisions, preparation outcomes, listening records, transcripts, retirement, and a `stat`-derived availability flag, indexed by `ItemID`. The model renders it. No journal decoding participates in reconstruction; `preparationRuns(limit:)` is called only by Prep/diagnostics.

**5. How failed/interrupted work is represented and recovered.** Download failures carry a durable `failureKind` (`retryable` | `terminal`) classified from `PodcastDownloadCoordinatorError`; `resumablePodcastDownloads()` returns `.queued`, `.downloading`, and `.failed(kind: .retryable)`. Preparation interruption is detected by the absence of an outcome row for the current ready revision, never by journal contents; `closeInterruptedPreparationRuns` is gated so it cannot stamp `.failed` where an outcome row proves success. Media loss is a snapshot-level availability flag plus a repair path triggered by `.podcastMediaUnavailable`.

**6. How the four retirement-adjacent concepts differ.**

| Concept | Record | Meaning | Reversible | Destroys |
| --- | --- | --- | --- | --- |
| Finished listening | `PodcastListeningRecord` (item-scoped) | the user reached the end | no (it is history) | nothing |
| Larder retirement | `retiredAt` on the episode record | out of the active decision queue | yes, clear the column | nothing |
| Feed dismissal | `PodcastEpisodeDismissalRecord` (V8) | feed refresh must not re-admit | via `restorePodcastEpisode`, but returns a bare row | episode + queue + download + speed + artwork + revision + transcript + playback rows |
| Media reclamation | none (filesystem) | free bytes | re-download | the file only |

Automatic retirement on completion is retained because it is the desired product behavior; automatic *dismissal* on completion is removed. Dismissal stays a user action.

**7. Which tests change and what is new.** Listed per phase, plus the mapping table under "Required test coverage".

**8. Migration strategy.** One schema bump, V9→V10, all-additive and lightweight, plus an idempotent post-open backfill. Detail under "Migration strategy".

## State dimensions

| Dimension | Authoritative record | Values | Writer | Read by |
| --- | --- | --- | --- | --- |
| Source acquisition | `PodcastDownloadRecord` (V6 entity, + new `failureKind`) | `none`, `queued`, `downloading(received:expected:)`, `completed`, `failed(retryable\|terminal)`, `cancelled` | `PodcastDownloadCoordinator` only | snapshot, automation, Larder |
| Preparation outcome | `PodcastPreparationOutcomeRecord` (new, key `episodeID + revisionID`) | absent, or `succeeded(revisionID, policyDigest, pipelineFingerprint, semanticVersion, producedAt)` | `PodcastPreparationPipeline.commit` only, same save as `replaceReadyRevision` | snapshot, Prep |
| Media availability | filesystem (no record) | `present`, `missing`, `unverified` | reconciler (snapshot build, post-fault repair) | snapshot, `canPlayEpisode` |
| Listening completion | `PodcastListeningRecord` (new, item-scoped) | `unheard`, `inProgress(positionSeconds, revisionID)`, `completed(at:, revisionID)` | `PlaybackController` checkpoint path only | snapshot, Menu, history |
| Larder visibility | `retiredAt: Date?` on `PodcastEpisodeRecord` | `active`, `retired(at:)` | lifecycle service (model-issued) | Larder, Menu |
| Reprocessing eligibility (derived) | computed from the outcome record + rule table | `current`, `eligible(rule:)`, `invalid(rule:)` | rule evaluation at bootstrap | Prep, Larder badge |

`PlaybackRecord` (revision-scoped, key `itemID|revisionID`) is retained as the resume-position fact. It is not the completion fact, because `replaceReadyRevision` deletes and re-inserts a carried copy and `dismissPodcastEpisode` deletes them all. Completion is about the episode, so it is item-scoped.

## Transition table

**Download**

| From | Event | To | Durable write | Side effects |
| --- | --- | --- | --- | --- |
| `none` | user or automation start, claim taken (`claimPodcastDownload`, 2554-2583) | `queued` | claim row | UI message |
| `queued` | transfer begins | `downloading` | status + bytes | progress to `onStatus` |
| `downloading` | bytes verified, hash matched | `completed` | `finalizePodcastDownload` (2890-2921), one save | admit automatic preparation |
| `downloading` | `transport` / `invalidResponse` | `failed(retryable)` | status + `failureKind` | throws to caller; automation retries in-process |
| `downloading` | `invalidURL`, `unsupportedMediaType`, `mediaTypeMismatch`, `declaredSizeTooLarge`, `hashMismatch`, `invalidAudio` | `failed(terminal)` | status + `failureKind` | throws; automation does not retry, counts as not downloaded |
| any | cancellation | `cancelled` | status | not a failure; automation returns its partial count |
| `failed(retryable)` | next launch reconciliation | `queued` | status | included by `resumablePodcastDownloads()` |
| `failed(terminal)` | user action only | `queued` | status | never auto-retried |

**Preparation**

| From | Event | To | Durable write |
| --- | --- | --- | --- |
| no outcome for ready revision | admission | `preparing` (ephemeral) | none |
| `preparing` | worker success, artifact published | outcome present | `replaceReadyRevision` + outcome row, **one save** |
| `preparing` | worker failure | no outcome | journal terminal `.failed` (best-effort, diagnostic only) |
| `preparing` | process exit | no outcome for the new revision | previous outcome row, if any, is untouched |
| outcome present | ready revision replaced by a later run | outcome for the new revision | new row; the old row is retained as history |
| outcome present | explicit invalidation rule matches | `invalid(rule:)` | eligibility column set; row not deleted |

The journal (`PreparationRecord`, `record(preparation:)` 1652-1660) keeps its `try?` write. It is evidence, not proof. The pre-run `clearPreparationJournal` stays but can no longer destroy readiness because readiness no longer reads the journal.

**Playback completion**

| Path | Event | Transition | Where |
| --- | --- | --- | --- |
| successor queued | backend finished | listening → `completed`, then retirement | `checkpointCompletedRevision` (controller 504-524) writes the listening row in the same call; the model issues retirement after the handler returns, outside the successor-load `do` (461-482) |
| no successor | backend finished | identical | `handlePodcastPlaybackFinished()` (4608-4643) calls the same lifecycle method |
| manual | `markCurrentPlaybackCompleted()` (3742-3763) | identical | same lifecycle method; `retireFinishedEpisode()` (3778-3787) is replaced |
| successor load throws | `.podcastMediaUnavailable` | listening `completed` and retirement both stand | retirement is not inside the failing block |

Retirement is idempotent: retiring an already-retired episode is a no-op returning `false`.

**Retirement and dismissal**

| Operation | Writes | Leaves | Trigger |
| --- | --- | --- | --- |
| retire | `retiredAt` | everything else, including media, revision, transcript, listening | completion, or user "remove from Larder" |
| un-retire | clears `retiredAt` | — | user restore |
| dismiss | dismissal marker + the existing cascade (2762-2797), minus the listening row | media bytes, dismissal marker, preparation journal, listening history | user action only |
| reclaim media | filesystem delete + availability flag | all records | user action (Phase 6 exposes the state; the action itself is out of scope) |

The single behavioral change inside `dismissPodcastEpisode` is that `PodcastListeningRecord` rows are not deleted, so "I listened to this" survives dismissal and restore.

**Media availability**

| From | Event | To | Cost |
| --- | --- | --- | --- |
| `unverified` | snapshot build | `present` / `missing` | one `stat` per ready revision |
| `present` | `PlaybackControllerError.podcastMediaUnavailable` | `missing` | none; the fault already exists (controller 527-560) |
| `missing` | re-download completes | `present` | covered by the download boundary |
| `present` | explicit verify / redownload request | `present` / `missing` | full-file hash, on demand only |

No hashing on render. Full hashing stays confined to the existing explicit paths (`localFileContentHash` inside invalidation, store 1727) and to a user-initiated verify.

## Atomicity boundaries

| # | Boundary | Today | Change |
| --- | --- | --- | --- |
| A | Download finalize | `finalizePodcastDownload`, single save (2890-2921) | none |
| B | Preparation commit | `replaceReadyRevision`, single save (2935-2997); outcome journaled afterwards with `try?` | outcome row inserted in the same save; `journalTerminal` becomes diagnostic-only |
| C | Source-file deletion after commit | inside `commit(...)` immediately after the save | moved out of the commit into a separate idempotent reclamation step that runs only after the outcome row is durable |
| D | Listening completion | `checkpointCompletedRevision` writes the playback row | same call also writes the item-scoped listening row |
| E | Retirement | implicit, inside the model's dismissal cascade, only on one path | separate idempotent store transaction after D, identical on both paths |
| F | Dismissal | single save (2762-2797) | unchanged except the listening-row exclusion |

Boundary C is the reason the plan separates commit from cleanup: today a crash between "outcome durable" and "source deleted" is harmless, but a crash between "source deleted" and "outcome durable" costs a network download. Reordering makes the expensive direction impossible.

## Crash and interruption recovery per boundary

| Boundary | Crash before | Crash after | Recovery on relaunch |
| --- | --- | --- | --- |
| A | download row is `queued`/`downloading` | download `completed` | `resumablePodcastDownloads()` re-queues; the coordinator's `expectedContentHash` check makes a repeat transfer safe |
| B | no outcome for the new revision; old outcome intact | outcome durable, artifact durable | snapshot shows the previous prepared state, or not-prepared; never "prepared" without bytes, never "not prepared" over a proven artifact |
| C | source file still present, outcome durable | source gone, outcome durable | reclamation is idempotent; a leftover source is deleted on the next pass, never a redownload |
| D | listening row absent; resume position from `PlaybackRecord` stands | listening `completed` durable | no oscillation: completion is one row, one writer |
| E | listening `completed`, episode still active in the Larder | retired | retirement is re-issued on the next snapshot for any episode with `completed` listening and no `retiredAt` (idempotent reconciliation) |
| F | episode present with dismissal marker absent | marker present, rows gone | existing idempotent behavior (returns `false` on repeat) retained |

The pipeline's pre-run `clearPreparationJournal` no longer participates in recovery at all. `closeInterruptedPreparationRuns(in:)` (4444-4450) is gated: it may write an interrupted `.failed` entry only when no outcome row exists for the episode's current ready revision.

## Migration strategy

One bump, V9→V10, landing in Phase 2 with every field the later phases need, so no phase after 2 touches the schema.

`LocalLibrarySchemaV10Models` adds:

- `PodcastPreparationOutcomeRecord` — `id` (`"<episodeID>|<revisionID>"`), `episodeID`, `revisionID`, `policyDigest`, `pipelineFingerprint`, `semanticVersion`, `producedAt`, `eligibility` (`String`), `invalidationRuleID` (`String?`).
- `PodcastListeningRecord` — `id` (`episodeID`), `completedAt: Date?`, `lastRevisionID: String?`, `updatedAt`.
- `PodcastEpisodeRecord.retiredAt: Date?` (nullable addition; V9 already added nullable `notes`, the same shape).
- `PodcastDownloadRecord.failureKind: String?` (nullable addition).

All four are new entities or nullable columns, so the stage is `.lightweight`, matching every existing stage in `LocalLibraryMigrationPlan` (1134-1150). The V5 preflight retention (`migrationBackupURL`, guarded by `hasV6PodcastTables(at:)`) is untouched.

Backfill runs as an idempotent store-level step after open, not as a SwiftData custom stage, because it decodes journal JSON and touches the filesystem — neither belongs in a migration stage, and a custom stage that fails leaves an unopenable store. `reconcilePodcastStateV10()`:

1. For each episode with a ready revision and no outcome row, find the newest journal terminal success whose `terminalResult.revisionID` matches; insert an outcome row with `pipelineFingerprint` taken from the entry's evidence when present, otherwise `nil`. A `nil` fingerprint means "prepared by an unknown earlier pipeline" and evaluates to `eligibility = .current` — legacy artifacts stay playable.
2. For each episode whose newest revision has a `PlaybackRecord` with `completed == true` and no listening row, insert `completed(at: record.updatedAt, revisionID:)`.
3. `retiredAt` is left `nil` for every existing row. Nothing is retroactively retired; an episode already dismissed keeps its marker and stays out of the Larder as before.
4. Existing `podcast-invalidation|` and `podcast-reset-preparation|` marker rows are read once, translated into `eligibility`/`invalidationRuleID` on the matching outcome rows, and deleted.

Step 1 is the load-bearing compatibility promise and gets its own test: a V9 store whose only proof of preparation is a journal terminal must come out of migration with the episode still Prepared.

Migration tests follow the existing programmatic-fixture pattern. Add `createV9MigrationFixture(at:...)` next to `createV2MigrationFixture` (1359) and `createV5MigrationFixture` (1372), and add tests mirroring `testV2StoreMigratesArticlePlaybackAndSafeNewDefaults` (LocalLibraryStoreTests 203) and `testV5RowsRemainReadableAfterAdditiveV6Migration` (837). `testForcedMigrationFailureLeavesEveryCheckpointedStoreFileIdentical` (1133) must still pass unchanged.

## iOS and CloudKit impact

None today, and none introduced by this plan.

`WiltedRecordType` (`WiltedKit/Sources/WiltedSync/RecordTypes.swift`) defines exactly `item`, `revision`, `revisionChunk`, `transcript`, and `playbackState`. There is no podcast episode, download, dismissal, preparation, or journal record type. `queueCurrentPlaybackCheckpoint()` (`WiltedMac/WiltedMacModel.swift:4080-4093`) guards on `selectedArticleID == playbackItemID.rawValue` and `articles.contains(where:)`, so only article playback is ever enqueued for sync. Podcast playback state never leaves the Mac, and the iOS listener has no podcast handling.

Consequences: all four new V10 records are local-only, and `LocalLibrarySyncRepository` needs no change. If podcast sync is ever added, the item-scoped listening record will need its own merge rule, because the existing transfer and resume-merge invariants are revision-scoped and an item-scoped completion fact has different conflict semantics (last-writer-wins on `completedAt` is the obvious default). That design is deliberately not attempted here. `INVARIANTS.md` should record this constraint in Phase 2 so it is not rediscovered.

## Retained, replaced, deprecated

**Retained unchanged**

| Item | Location | Why |
| --- | --- | --- |
| `PodcastDownloadCoordinator.download(...)` | coordinator 177-387 | already the correct typed throwing contract |
| `finalizePodcastDownload` | store 2890-2921 | already atomic |
| `claimPodcastDownload` | store 2554-2583 | claim scoping is correct |
| `withRetries` | automation 321-336 | bounded retry is correct; it just needs real failures |
| Playback generation guards, session epochs, `PlaybackIntent` | controller | correct and subtle; do not touch |
| `PodcastEpisodeDismissalRecord` (V8) | store | feed re-admission suppression, unchanged meaning |
| `migrationBackupURL` preflight | store | unchanged |
| `PreparationRecord` / `record(preparation:)` / `preparationRuns(limit:)` | store 1652-1660, 1933-1972 | retained as Prep history and diagnostics; demoted from readiness authority and no longer read by the Larder projection |
| `hiddenEpisodeIDs` | model 2668-2674 | legitimate optimistic UI, reconciled by the store result |
| `WiltedMacEpisodeLifecyclePresentation` | model 512-585 | becomes the single derived display label |

**Replaced**

| Item | Location | Replacement |
| --- | --- | --- |
| `downloadEpisode(_:alreadyClaimed:ignoringExisting:)` | model 2005-2118 | `startDownload(_:) async throws -> PodcastDownloadOutcome` plus a thin non-throwing UI wrapper that presents and rethrows nothing |
| `podcastDownloadTasks: [String: Task<Void, Never>]` | model 1174 | `[String: Task<PodcastDownloadOutcome, Error>]` |
| `startClaimedDownload(_:)` | model 1613-1623 | awaits the throwing task; `claimedEpisodeMissing` retained |
| in-memory `.prepared(summary:)` override | model 2374 | deleted; readiness comes from the outcome row |
| `preparationState(run:readyRevisionID:transcript:)` | model 4807-4832 | `preparationState(outcome:readyRevisionID:)`, no journal input |
| `invalidateStalePodcastPreparations(currentFingerprint:)` | store 1688-1816 | `evaluateReprocessingEligibility(currentFingerprint:rules:)` — sets eligibility, never deletes journals, never writes forced-redownload markers except under an explicit rule |
| forced/reset marker pseudo-entries; `requiresForcedRedownload`; `markForcedRedownloadCompleted` | store 1746-1786, 1839-1869, 1877-1882 | `eligibility` / `invalidationRuleID` columns on the outcome record |
| `readyRevision(for:revisionID:)` full-table scan | store 1597-1607 | scoped fetch inside the snapshot; the standalone method stays for single-episode callers |
| `loadLibrary(from:)` per-episode assembly | model 4679-4768 | `store.podcastLibrarySnapshot()` |
| `retireFinishedEpisode()` (hide + dismiss) | model 3778-3787 | `retireEpisode(_:)` writing `retiredAt`; dismissal only on user action |
| fixture download branch | model 2007-2040 | fixture `PodcastDownloadTransporting` on the real code path |

**Deprecated**

| Item | Location | Disposition |
| --- | --- | --- |
| `unfinishedPodcastDownloads()` | store 2585-2593 | superseded by `resumablePodcastDownloads()`; kept as a deprecated shim for one release |
| `DeferredAutomaticPreparation` + `UserDefaults` envelope | model 2133-2177, 2258-2273 | durable state in the wrong store; moves to a store-backed admission queue in Phase 8 |
| `closeInterruptedPreparationRuns` / `interruptedPreparationEntry` | model 4444-4450, 4458-4471 | retained but gated on the absence of an outcome row; it may no longer stamp `.failed` over a proven artifact |

## Required test coverage

| Issue checkbox | Phase | Test |
| --- | --- | --- |
| Download fails through model → automation adapter | 3 | `WiltedMacTests`: real `WiltedMacModel` + real `PodcastDownloadCoordinator` + failing stub transport + real `WiltedAutomationCoordinator`; asserts `completed == 0`, retry count, and final status |
| Preparation commits then dies before terminal write | 4 | `WiltedProducerTests`: pipeline with a runner that succeeds, store injected to fail the journal write; reopen; assert Prepared, and assert the same across two consecutive reopens (no oscillation) |
| Natural finish with and without a successor | 5 | `WiltedMacTests`: both paths produce identical listening + retirement rows; plus a successor-load-throws variant |
| Prepared episode's media disappears | 6 | `WiltedMacTests`: delete the file, rebuild the snapshot, assert unavailable presentation, `canPlayEpisode == false`, and outcome + listening rows intact |
| Fingerprint change without incompatibility | 7 | `WiltedProducerTests` + `WiltedMacTests`: bump the fingerprint, assert artifact still playable and eligibility reported separately; no forced redownload scheduled |
| Refresh/relaunch across every preparation state | 4, 5 | parameterised over queued / running / cancelled / failed / completed |
| Restore/dismiss independent of played/completed | 5 | dismiss a completed episode, restore it, assert the listening row survived both |
| Existing-store migration covers new records | 2 | V9 fixture → V10, including the journal→outcome backfill and the playback→listening backfill |

New test files need no manifest edit: `project.yml` sources `WiltedMacTests` by directory glob and SwiftPM auto-discovers Producer tests. Verify by file-count delta in the same commit regardless.

Existing tests that will change: `testMarkingTheCurrentEpisodeCompletedRetiresItFromTheLarder`, `testAnEpisodeAlreadyMarkedCompletedCanStillBeRetired`, `testANaturallyFinishedEpisodeStartsTheNextReadyOneAndRemovesItself`, `testNaturalCompletionSkipsAnUndownloadedEpisodeToReachTheNextReadyOne` (retirement no longer dismisses); `testPreparationStateComesFromWhatTheLibraryCanProve`, `testPreparedSummaryIsRecoveredFromTheJournal` (proof source changes from journal to outcome row); `testDismissingAPreparedEpisodeClearsItsRevisionTranscriptAndPlayback` (listening row must now survive); the four `testPipelineInvalidation*` cases (invalidation becomes eligibility); `testLibraryProjectionDoesNotCapPreparationEvidenceAtThePrepDisplayLimit` (projection no longer reads evidence).

## Phases

### Phase 1 — real-wiring seams

Add `podcastDownloadTransportFactory` and `podcastPipelineRunnerFactory` parameters to `WiltedMacModel.init(...)` (1208-1219) and thread them through `configureStoreDependencies(_:)` (4499-4508). Collapse the fixture download branch (2007-2040) onto the real path behind a fixture `PodcastDownloadTransporting` that emits the same progress and failure shapes, so `--wilted-ui-fixture-download-failure` exercises production code. No behavior change, no schema change.

**Gate:** existing `macos-unit-tests` and `wiltedproducer-tests` legs pass unchanged; the four modified pixel snapshot baselines are byte-identical; one new test drives a download end-to-end through the model with a stub transport. Docs: none.

### Phase 2 — V10 substrate

Add the four schema additions, the lightweight stage, the store read/write APIs for outcome, listening, retirement, and download `failureKind`, and `reconcilePodcastStateV10()`. Add `createV9MigrationFixture`. No model or pipeline behavior change yet; the new records are written by nothing and read by nothing.

**Gate:** migration tests pass from V2, V5, and V9 to V10; backfill is proven idempotent by running it twice and asserting row equality; `testForcedMigrationFailureLeavesEveryCheckpointedStoreFileIdentical` still passes. Docs: `README.md` schema-version note; `INVARIANTS.md` gains an entry for orthogonal episode state dimensions (presentation is derived, never persisted) and the CloudKit merge-rule constraint above; `HISTORY.md` entry with `files:` and `inv:` citations. Note both `HISTORY.md` and `TASKS.md` are gitignored here (`.gitignore:49-50`) because the remote is public — update them, do not force-add them.

### Phase 3 — download result contract and automation truth

Change the task table type, make `startDownload` throwing, make `startClaimedDownload` propagate, add `failureKind` classification in the coordinator's final catch (375-386), add `resumablePodcastDownloads()`, and wire bootstrap reconciliation (`performStoreBootstrap()`, 4358-4431) to it. The UI wrapper presents failures; orchestration receives them.

**Gate:** the automation integration test above; a bounded-retry test proving `withRetries` fires exactly three times for a `transport` error and zero times for `hashMismatch`; a relaunch test proving a `retryable` failure is re-queued and a `terminal` one is not. Docs: `docs/automation.md` retry-policy section; `HISTORY.md`.

### Phase 4 — durable preparation outcome

Move the outcome insert into `replaceReadyRevision`'s save, move source deletion out of `commit(...)` into a separate reclamation step, delete the `.prepared(summary:)` override (2374), repoint `preparationState(...)` at the outcome row, gate `closeInterruptedPreparationRuns`, and narrow `applyingRunningPreparations` to `.preparing`.

**Gate:** the commit-then-crash test; a double-reopen no-oscillation assertion; a test proving a failed `journalTerminal` write does not change readiness; the five reconstruct-across-relaunch cases. Docs: `README.md` preparation-proof paragraph; `HISTORY.md`.

### Phase 5 — completion, retirement, dismissal

Write the listening row inside `checkpointCompletedRevision`, introduce one `completeAndRetire(_:)` lifecycle method called identically from `handleBackendCompletion`'s successor path, `handlePodcastPlaybackFinished()`, and `markCurrentPlaybackCompleted()`, with retirement as a second transaction outside any load `do` block. Stop deleting listening rows in `dismissPodcastEpisode`. Add the completed-without-`retiredAt` reconciliation pass to bootstrap.

**Gate:** successor / no-successor / manual / successor-load-throws all produce identical durable state; dismiss-then-restore preserves listening history; retirement idempotency under repeated reconciliation. Docs: `README.md` Larder semantics; refreshed screen-by-screen walkthrough is deferred to Phase 9. `HISTORY.md`.

### Phase 6 — media availability

Add the availability flag to the snapshot via one `stat` per ready revision, repair it on `PlaybackControllerError.podcastMediaUnavailable`, gate `canPlayEpisode` (2989) and `canSelectNextEpisode` (3063-3067) on it, and add the "Prepared · Local audio missing — Download again" presentation to `WiltedMacEpisodeLifecyclePresentation`.

**Gate:** the missing-file test; a test asserting no hashing occurs during snapshot construction (inject a counting file-manager seam); pixel snapshots updated deliberately for the new presentation. Docs: walkthrough note; `HISTORY.md`.

### Phase 7 — reprocessing eligibility

Replace blanket fingerprint invalidation with an explicit rule table (`invalidationRuleID` → predicate over `semanticVersion` / `pipelineFingerprint`), seeded empty so that today's source drift invalidates nothing. Keep forced redownload available only as a rule consequence. Serialize any resulting recovery work through bounded admission rather than task-per-ID.

**Gate:** the fingerprint-change-without-incompatibility test; a test proving one seeded known-bad rule does invalidate and does schedule recovery; a bootstrap test proving at most N concurrent recoveries. Docs: `README.md` pipeline-versioning section; `HISTORY.md`.

### Phase 8 — batched snapshot and residual ephemeral state

Implement `podcastLibrarySnapshot()` with scoped, indexed reads; repoint `loadLibrary(from:)` at it; remove the duplicate `podcastEpisodes()` call and the `preparationRuns(limit: Int.max)` call from the projection path. Move `DeferredAutomaticPreparation` out of `UserDefaults` into the store.

**Gate:** a read-count test (instrumented store) proving snapshot cost is bounded and does not scale per-episode in full-table fetches; `testLibraryProjectionDoesNotCapPreparationEvidenceAtThePrepDisplayLimit` reworked against the Prep path; all prior phase tests still green. Docs: `README.md` projection description; `HISTORY.md`.

### Phase 9 — closeout

Full `scripts/test-gate.sh`, then the deferred macOS XCUITest leg once (`WILTED_MAC_UI=1` / `make native-ui`) against the accumulated change, then a dated screen-by-screen walkthrough covering the new unavailable-media and retired states. Port verified `TASKS.md` rows into `HISTORY.md` and delete them.

**Gate:** every named leg green; the UI leg reported separately if the device gate is unavailable; walkthrough reviewed before any install or release.

## Ordering

Phase 1 precedes everything because the issue's first two required tests cannot exist without the seams. Phase 2 precedes 3 through 7 so there is exactly one schema bump and one migration to test, rather than four. Phase 4 precedes 5 because completion semantics reference the preparation outcome. Phase 6 precedes 7 because eligibility rules must be able to distinguish "artifact missing" from "artifact outdated". Phase 8 is last among the behavioral phases because a batched snapshot built before the dimensions settle would be rewritten twice. Any phase failing its gate leaves the prior durable state intact; no phase is partially shippable across a schema boundary.

## Exclusions

Media reclamation UI, podcast CloudKit sync, the thinner-model refactor beyond what the phases require, detector and FFmpeg work from the reliability deep plan, and any UI label change not required by a new state dimension.

---

## What the issue gets factually wrong

1. **"The underlying download operation needs a real result contract, ideally an `async throws` operation."** It already has one. `PodcastDownloadCoordinator.download(...)` (`Producer/Sources/WiltedProducer/PodcastDownloadCoordinator.swift:177-387`) is `async throws -> PodcastDownloadResult` with typed errors and a rethrowing final catch. Nothing in the Producer layer needs to change for this finding; the entire defect lives in three places in `WiltedMacModel` (2005-2118, 1174, 1613-1623). Scoping the fix as a Producer change would be wasted work.

2. **"Coordinator comments say failed work can be resumed later."** No such comment exists. The doc comment on `unfinishedPodcastDownloads()` (`LocalLibraryStore.swift:2585-2593`) explicitly defines the resumable set as `.queued` and `.downloading` and explains why ("`queued` is claimed and not started, `downloading` is a transfer with no process behind it any more. Both are resumable"). It never mentions failed downloads. The real gap is a missing policy for `.failed`, not a comment contradicting code — which matters because the fix is a decision, not a bug fix.

3. **The preparation finding omits the more damaging ordering problem.** `prepare()` calls `clearPreparationJournal` *before* any work begins. For an already-prepared episode that deletes the only durable proof of the previous success before producing a replacement, so a crash mid-run downgrades a valid artifact to Not Prepared even if the terminal write mechanism were perfectly reliable. Fixing only the post-commit `try?` write would leave this path intact.

4. **"`dismissPodcastEpisode()` ... Media bytes are intentionally left on disk"** is correct but the stated reason matters: bytes are kept because `RevisionID` is content-addressed and two episodes with identical bytes share one revision, so deleting the file could break a surviving episode. Any future media-reclamation feature inherits that constraint and cannot simply delete by episode.

5. Minor: the issue says `loadLibrary()` "separately" looks up ready revision, playback, transcript, and preparation state. True, and it additionally calls `store.podcastEpisodes()` twice in the same pass (4705 and 4723), which the finding does not mention and which is the cheapest thing to fix.

Everything else in the issue matched the code, including the `preparationRuns(limit: Int.max)` call (4719), the `.prepared(summary:)` override (2374), the successor/no-successor asymmetry, the absence of a file-existence check in `readyRevision` (1597-1607), the fingerprint's inclusion of speech-stack Python sources (455-536), and the restore-returns-bare-row behavior (2617-2645).

## Decisions that need the repo owner

1. **Automation download retryability.** Default adopted above: `transport` and `invalidResponse` are `retryable` — bounded in-process retry via the existing `withRetries`, claim stays `queued`, re-queued at next launch; `invalidURL`, `unsupportedMediaType`, `mediaTypeMismatch`, `declaredSizeTooLarge`, `hashMismatch`, `invalidAudio` are `terminal` — no auto-retry, excluded from relaunch reconciliation, user action only; `cancelled` is neither. The genuinely open half is whether a `retryable` failure should be re-queued automatically at next launch (default here: yes) or wait for the user, since automatic re-queue means a persistently dead feed retries on every launch forever.

2. **Relationship to `docs/2026-09-11-lifecycle-reliability-deep-plan.md`.** That plan's Phase 1 covers the same completion and bootstrap-invalidation ground, and its lifecycle contract is a single enum. This plan assumes supersession of its Phase 1 and reinterprets its contract as presentation-only. If that plan is already partly implemented in a dirty working tree at implementation time, the ordering has to invert and this plan rebases.

3. **Listening completion scope.** This plan proposes a new item-scoped `PodcastListeningRecord` because `PlaybackRecord` is revision-scoped and is deleted by both `replaceReadyRevision` and `dismissPodcastEpisode`. The alternative — stop deleting revision-scoped playback rows — is a smaller change but keeps completion tied to a revision that preparation replaces, which is exactly the coupling the issue objects to.

4. **Automatic retirement on completion.** The plan keeps it (completion retires from the Larder) and removes only the automatic *dismissal*. If the intent is that finishing an episode should leave it visible until explicitly removed, Phase 5 changes shape.

5. **Backfilling `retiredAt` for already-completed episodes.** The plan leaves it `nil`, so previously completed-but-not-dismissed episodes reappear as active in the Larder after migration. The alternative is to retire everything with a completed playback record at backfill, which is tidier but silently removes rows the user may expect to see.

6. **Whether `DeferredAutomaticPreparation` moves out of `UserDefaults`.** The plan schedules the move in Phase 8. It is durable state in the wrong store, but moving it is not required by any issue finding and could be deferred indefinitely with a comment saying why.
