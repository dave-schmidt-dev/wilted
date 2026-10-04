# Invariants — wilted

> Native Mac producer and iOS listener contract for the post-reset project. Invariant identifiers use the harvest-compatible `W-INV-*` namespace and must not be confused with the archived Python charter.

## What `gate_test: test-gate.sh` proves

Every invariant below names `test-gate.sh` as its gate. As of 2026-08-26 that
script runs eight of its nine legs unconditionally and **defers the ninth**,
`macos-ui-tests`, unless `WILTED_MAC_UI=1` (`make native-ui`).

macOS XCUITest has no headless mode. It drives real HID events through
WindowServer, so the leg seizes the cursor, keyboard, and window focus for its
entire run and cannot share a machine with its operator. Deferring it by
default is a deliberate trade, recorded here because it changes what a green
gate means.

A deferred leg is not a passed leg. The gate counts deferrals separately, names
them in `native.deferred`, and never emits an unqualified `native.passed` when
any leg was deferred; `tests/test-native-gate.sh` asserts all three and is
mutation-tested against both the "silently pass" and "never defer" regressions.
So a green `make validate` is honest about owing the Mac UI leg, but it is not
evidence that leg ran. Only `make native-ui` is.

Invariants whose evidence depends on the real Mac UI surface — W-INV-005 and
W-INV-010 in particular — are therefore only fully gated by `make native-ui`.
Two facts about the Mac UI suite make it irreplaceable rather than merely
convenient, and both were measured rather than assumed (see HISTORY.md,
2026-08-26): a `NavigationSplitView`'s navigation column is not drawn by
`NSHostingView.cacheDisplay`, so no pixel baseline can cover the sidebar; and
the AppKit accessibility tree does not materialize without an attached AX
client, so no offscreen unit test can prove an accessibility identifier or
label reached the tree.

## Standing invariants

### W-INV-001 — No silent blocking waits
area: ["WiltedMac/**", "WiltediOS/**", "Producer/**", "WiltedKit/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Every network, subprocess, extraction, speech, transfer, cache, and other stall-prone operation exposes live, cancellable progress on the active UI surface and reaches a bounded failure state.

## Project-specific invariants

### W-INV-002 — Mac-only producer and iOS listener
area: ["WiltedMac/**", "WiltediOS/**", "Producer/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Mac owns ingestion, preparation, and publication; iOS is a listener. iOS mirrors Mac library state and sends only idempotent intents plus its own playback progress; it never writes producer or library state directly. No target silently assumes the other's responsibilities.

### W-INV-003 — Source-kind-namespaced stable IDs and immutable audio revisions
area: ["WiltedKit/**", "Producer/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Stable item identity and immutable revision identity prevent mutations from attaching playback or delivery state to the wrong audio. Existing article identity remains unchanged. Podcast feed ItemID derives from its canonical feed URL; podcast episode ItemID derives from canonical feed URL plus normalized RSS GUID, falling back to canonical enclosure URL only when the GUID is absent. Both podcast ItemID derivations are source-kind-namespaced so they cannot collide with articles. Downloaded-media RevisionID is source-kind-namespaced and derived from the verified audio content hash, so unchanged bytes retain identity across re-downloads or enclosure URL churn, changed bytes produce a new immutable revision, and podcast revisions cannot collide with TTS revisions.

### W-INV-004 — Atomic producer outputs
area: ["Producer/**", "WiltedMac/**"]
gate_test: test-gate.sh
threshold: 3
rationale: A failed or cancelled preparation never replaces the last valid media; a ready revision is exposed only after its complete, self-contained transfer file is durable. Podcast enclosure downloads remain temporary until bounds, content hash, and media validation succeed and one atomic move publishes the immutable local revision. Cancellation or failure removes only temporary bytes and preserves every prior playable revision.

### W-INV-005 — UI does not write producer state
area: ["WiltedMac/**", "WiltedKit/**"]
gate_test: test-gate.sh
threshold: 3
rationale: SwiftUI presentation and interaction invoke domain operations; producer/library state is changed only through the producer service and shared contracts. A position the iPhone reports is such a change: the phone only publishes a record, and the Mac adopts it into its stored playback state through `PlaybackController.applyRemotePosition` (never from the UI, never by the phone writing library state).

### W-INV-006 — Resume merge preserves intent
area: ["WiltedKit/**", "WiltediOS/**", "WiltedMac/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Playback state carries revision ID, position, completion, session epoch, explicit restart/rewind intent, and update time. Merge rules preserve intentional rewinds/restarts and reject incompatible revisions. After an explicit rewind or restart, later Mac and iPhone checkpoints retain that intent for the session; compatible pending listener playback rebases against fetched server state before retry. A position adopted from another device is stamped with the time that device saved it and is refused when it is not newer than the stored one, when its epoch is below the highest seen for the entry, when it is for another revision, or when the episode is finished or playing; a backward move by a newer record is an intentional rewind and starts a rewind session.

### W-INV-007 — CloudKit transfer with local cache
area: ["WiltedKit/**", "WiltedMac/**", "WiltediOS/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: CloudKit is a transfer service, not the source of truth or a real-time channel. Library state travels on a single-writer channel (only the Mac writes it) and each device keeps its own handoff record, so devices never overwrite one another's handoff state. Both apps retain local state; the Mac publishes an offer for a completed revision and uploads its audio only on request, as one verified asset (at most 250 MB) in its own WiltedMediaZone through raw operations, replacing bounded chunks for library sync. Every engine and scan is scoped to WiltedLibraryZone, so catalog fetches never stage audio, and iOS explicitly fetches that asset with progress, verifies its byte count and streaming SHA-256, and atomically caches it for offline playback; the asset record is deleted once every requesting device acknowledges it, or after 7 days. Persisted zone changes/deletions survive relaunch, but engine tokens advance only after corresponding local data or send acknowledgements commit; the legacy chunked article path keeps its own rule that pending chunks gate publication only for their own revision until it is retired. Every typed account change quarantines local work until explicit review resumes the current engine, and an operation generation prevents pre-quarantine fetch/send completions from committing afterward.

### W-INV-008 — Cross-target fixtures are authoritative
area: ["WiltedKit/**", "WiltedMacTests/**", "WiltediOSTests/**", "CloudSync/**", "Listener/**", "Producer/Tests/Fixtures/**", "Producer/Tests/WiltedProducerTests/LocalLibraryStoreTests*.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: Publish, decode, merge, completion, deletion, version mismatch, offline cache, partial failure, delayed delivery, typed account transitions, and deterministic account-change interleavings use shared fixtures so Mac and iOS cannot silently diverge.

### W-INV-009 — Release evidence remains separated
area: ["README.md", "TASKS.md", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: As of 2026-09-29, Mac owner acceptance no longer gates iPhone library-sync development, which proceeds in parallel; fresh iPhone or CloudKit qualification still needs its own evidence. Mac owner acceptance, portal capability configuration, local tests, simulator results, effective signed entitlements, Development CloudKit runtime, Production CloudKit, physical-device behavior, App Store Connect processing, and user-visible TestFlight are distinct evidence; none substitutes for another.

### W-INV-010 — Zero Delta Lettuce remains legible and native
area: ["Shared/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Wilted preserves Zero Delta structure, status semantics, native typography, accessibility, and flat surfaces while limiting the lettuce motif to a restrained identity mark and accent. Navigation stays literal, color never carries state alone, and light/dark behavior is snapshot- and contrast-tested. Larder's Add article action remains accessible after its last article is removed and when a search has no article matches. Larder never repeats Feeds' Keep/Skip decision; its Played label requires a durable completion record, and its completion control appears only for a started, unfinished row on the Mac; on the iPhone, a row whose audio is on the phone may also be marked completed (behind a confirmation), because the phone is where a downloaded episode is finished or abandoned.

### W-INV-011 — Episode state dimensions stay orthogonal and locally durable
area: ["Producer/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Download progress, preparation outcome, listening completion, and retirement are independent, separately-persisted facts about a podcast episode; no single stored enum collapses them, and any user-facing lifecycle label is derived from the current combination at read time rather than written as its own column. Preparation outcomes are keyed by revision, so a superseded revision's outcome never masks the current one; listening completion is keyed by item, since a listener's "done with this episode" intent outlives any one revision's replacement. `LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord` and `PodcastListeningRecord` are local-only SwiftData rows with no `WiltedRecordType` counterpart; podcast sync (W-INV-007) is not implemented for them, and if it ever is, the item-scoped listening record needs its own last-writer-wins-by-`updatedAt` merge rule distinct from the revision-scoped merge rules the CloudKit contract already covers, because two devices can independently mark the same item complete against different revisions.

### W-INV-012 — Verification is headless first; the screen-seizing Mac UI suite stays a few journeys
area: ["WiltedMacUITests/**", "WiltedMacTests/**", "scripts/test-gate.sh"]
gate_test: test-gate.sh
threshold: 3
rationale: The Mac XCUITest leg takes over the owner's cursor, keyboard, and focus, so it is reserved for what nothing headless can prove: real clicks reaching controls, popover and window presentation, keyboard shortcuts, hit-testing, and the live accessibility tree. Every other UI check is a model test, a pixel baseline, or a source assertion in `WiltedMacTests`, which run in `make validate` without touching the screen. `WiltedMacSmokeUITests` holds a few multi-step journeys, one launch each. An assertion that genuinely needs a real window joins an existing journey that already has the right fixture, and a new journey is added only when no existing launch can reach the state. The gate reads its test-count floor from the suite instead of pinning a number, so the suite can grow or shrink with the product, and a run that executes fewer tests than the suite declares still fails. The deferred leg is enforced at install time without driving the screen: `make install` runs `scripts/native-ui-receipt.py check-head`, which compares the tree being installed with the clean-commit, zero-failure, zero-deferral `make native-ui` receipt for the explicit Mac UI surface in `scripts/mac-ui-surface.paths`; a changed surface without that receipt cannot install unless `WILTED_SKIP_UI_RECEIPT=1` is set, which prints a warning naming the receipt it ignores. The pre-push hook runs `make validate` only. `WILTED_GATE_LEGS` runs a named subset of gate legs for diagnosis; such a run reports `filtered=<n>` and can never mint a receipt (`tests/test-native-gate-legs.sh`, `tests/test-native-ui-receipt.sh`).

### W-INV-013 — Ad recovery preserves uncertain programme
area: ["Producer/Workers/**", "Producer/Runtime/**", "Producer/Sources/WiltedProducer/Preparation/**"]
gate_test: test-gate.sh
threshold: 3
rationale: A classifier label, sponsor name, or pause is a reason to review audio, not permission to remove it. Unanchored host-read recovery is bounded by explicit commercial evidence, time and call limits, complete candidate text, and independent programme checks on the proposed cues and both sides. A cue still judged programme or mixed stays audible; a separately confirmed commercial suffix may be removed. Invalid or incomplete review keeps the audio. A changed worker records a new semantic version and source hashes so future preparations have distinct provenance; the production invalidation-rule table remains empty, so that fingerprint change alone does not condemn existing prepared audio. Prepared-copy diagnostics and owner reports identify gaps but cannot stand in for replay of a missing original aligned input or prove a current library revision has been repaired.

### W-INV-014 — Test processes and temporary scratch have bounded ownership
area: ["scripts/run-bounded.py", "scripts/lib/test-runner.sh", "scripts/lib/test-temp-state.sh", "scripts/check-temp-leaks.py", "scripts/build-with-cache.py", "scripts/test-gate.sh", "scripts/test-phase0.sh", "scripts/with-spec-scratch.sh", "scripts/lib/temp-sweep.sh", "scripts/check-no-global-tmp.py", "Producer/Runtime/Makefile", "Producer/Tests/WiltedProducerTests/PodcastPipeEOFTests.swift", "tests/test_bounded_runner.py", "tests/test_temp_leaks.py", "tests/test-build-with-cache.sh", "tests/test-bounded-entry.sh", "tests/test-no-global-tmp.sh"]
gate_test: test-gate.sh
threshold: 3
rationale: Stall-prone test and gate commands have finite deadlines, expose timeout progress, preserve command failure and signal outcomes, and clean up only their observed owned process tree; supervisor loss cannot silently leave observed descendants running. Project scratch is uniquely created below the inherited TMPDIR and cleaned after owned children stop; identity-based before/after entry sets audit each contained leg and the actual parent root, so a new entry fails even when totals shrink. Active scripts and documentation do not hard-code absolute global temporary roots, and stale cleanup requires an owned marker, inactive owner, prefix, and age cutoff. Implementation notes and verification records are retained in [`.logs/leak-repair-2026-09-28/`](.logs/leak-repair-2026-09-28/).

### W-INV-015 — CarPlay plays only what is on the phone, through the shared player, and stays inside Apple's audio-app rules
area: ["WiltediOS/CarPlay/**", "WiltediOS/Library/LibraryRuntime.swift", "WiltediOS/Library/LibraryFileProtection.swift", "WiltediOS/Library/FileMediaCache.swift", "WiltediOS/Info.plist", "WiltediOS/WiltediOS.entitlements", "WiltediOS/WiltediOSProduction.entitlements", "tests/test-carplay-config.sh", "WiltediOSTests/CarPlaySourceTests.swift", "WiltediOSTests/LibraryFileProtectionTests.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: The car offers listening only (docs/carplay-requirements.md, Apple's CarPlay Developer Guide and Entitlement Addendum). It lists episodes already on the phone, plays them through the same `LibraryPlayer` and `LibraryRuntime.shared` as the phone UI, so position sync, handoff and stats are unchanged, and starts without the iPhone window scene. The audio session is activated only by the player when playback starts, never at connect. Only list and now-playing templates are used, at most two deep, and every list-item handler calls its completion. Nothing the car reads needs an unlocked phone: cached audio, transcripts and the library snapshot use `completeUntilFirstUserAuthentication`, never `Complete` or `CompleteUnlessOpen`, and no keychain item uses a `WhenUnlocked` class. Car text never tells the driver to handle the phone, and there is no lyrics, search-as-primary, or non-audio content. The CarPlay audio entitlement is in the Development entitlements with manual signing against the profile that carries it; the Production entitlements get it only when CarPlay is ready for every user, because the icon then appears for everyone. Source assertions and `tests/test-carplay-config.sh` enforce this headless; the CarPlay Simulator and a real car are attended evidence.

### W-INV-016 — The apps keep one Wilted look, design and behavior, within reason
area: ["Shared/**", "WiltedMac/**", "WiltediOS/**", "WiltediOSIntents/**", "WiltedKit/Sources/WiltedLibrary/InProgressOrdering.swift", "docs/mockups/**"]
gate_test: test-gate.sh
threshold: 3
rationale: The Mac, iPhone, CarPlay and Siri surfaces are one product. They share the Wilted custom symbols and lettuce watermark from `Shared/`, the `WiltedTheme` palette and native typography, and the Mac/iPhone Larder row anatomy: artwork and title followed by the factual second line “Feed - total duration - publication date”, with playback progress and lifecycle/completion feedback separate. Mac visible row ordinals are contiguous across rendered rows and expose matching “X of Y” accessibility position; these presentation ordinals do not reorder the playback queue. CarPlay keeps its native-template row presentation, including progress and time-left information appropriate to the driver role. They share one play order (`InProgressOrdering.playOrder`: in progress newest play first, then not started oldest published first, then completed; manual start in the Larder advances forward through subsequent eligible episodes and stops cleanly at the end without wrapping backwards), and the same meaning for every shared action and label. A change to one surface's look, design or behavior is mirrored on the others in the same piece of work, or the gap is recorded in `TASKS.md` with its reason. Differences are allowed only where the platform or role requires them: the Mac is the rich editing surface (custom order, sort and grouping, two-pane layout with Now Playing and transcript), the iPhone stays simple (play order only, no sort, group or reorder), CarPlay is limited to Apple's templates and driver-safety rules (W-INV-015), and Siri is voice-only. `docs/mockups/` is the shared design baseline; pixel baselines and source assertions on each target are the headless evidence.

### W-INV-017 — One Mac playback command owner; the newest explicit command wins
area: ["WiltedMac/ViewModel/WiltedMacModel+PlaybackCommands.swift", "WiltedMac/ViewModel/WiltedMacModel+Playback.swift", "WiltedMacTests/WiltedMacPlaybackCommandTests.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: Mac playback commands (play, pause, seek, episode change) go through one owner on the model, so a command is acknowledged before its first await and a late completion cannot change what a newer command decided. A repeated Play press while a start is pending starts once; an explicit Pause or a newer episode selection supersedes the pending start; a seek during a pending start leaves playback paused at the new position; a backend refusal is visible and retryable, and a route fault recovers once without spending the retry budget on missing media. Enforced headless by `testPrimaryPressPublishesPendingBeforeFirstAwaitAndRepeatsStartOnce`, `testNewerSelectionSupersedesPendingEpisodeStart`, `testExplicitPauseDuringPendingStartWinsAndDuplicateToggleIsNotPause`, `testSeekDuringPendingStartLeavesPausedAtNewPosition`, `testBackendRefusalIsVisibleAndRetryStarts` and `testRouteFaultOnStartRecoversOnceAndStarts` in `WiltedMacPlaybackCommandTests`. Real clicks reaching the controls are attended `make native-ui` evidence.

### W-INV-018 — A pause after an episode ends holds the queue advance
area: ["Producer/Sources/WiltedProducer/PlaybackController*.swift", "WiltedMac/ViewModel/WiltedMacModel+Playback.swift", "WiltediOS/Library/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Continuing to the next queued episode is a decision made after an episode ends, and an explicit pause between the end and the next load cancels it: the next episode is not loaded, nothing is announced, and the stored queue still names the finished episode. A successor removed during the lookup is skipped rather than loaded. Enforced by `testAPauseAfterTheEndHoldsTheQueueAdvance` (`PlaybackControllerTests+QueueAdvance`), `testAPauseAfterTheEndCancelsTheQueueAdvance` (`WiltedMacLifecycleRegressionTests`) and `testAPauseAfterTheEndAndBeforeTheLookupCancelsTheContinuation` (`LibraryAutoContinueTests`).

### W-INV-019 — A normal Mac quit drains local work within 10 seconds and never waits on the cloud
area: ["WiltedMac/WiltedMacAppTermination.swift", "WiltedMac/Sync/WiltedMacSyncLifecycle.swift", "WiltedMacTests/WiltedMacTerminationTests.swift", "WiltedMacTests/WiltedMacTerminationLibraryJoinTests.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: On a normal quit the app pauses, stops admitting work, and writes the playhead, lifetime totals and in-flight download bytes inside a 10 s budget (`WiltedMacTerminationCoordinator.localBudget`). A failed or timed-out local drain cancels the quit visibly, keeps the app open and offers a retry; a late completion cannot reply a second time. Network work is cancelled and joined with only the budget that remains, and pending cloud sends are already durable in the local outbox, so a slow or unfinished cloud step never cancels a quit whose local work saved. A forced exit or crash skips the drain and loses at most the disclosed tails (about 10 s of listening time and 1 s of download bytes). Enforced by `testQuitDrainPausesNowWritesPlayheadAndTotalsAndStopsAdmission`, `testQuitDrainCancelsAndJoinsInFlightDownloadAndKeepsItsBytes`, `testTimedOutSaveCancelsQuitAndItsLateCompletionCannotReply`, `testFailedSaveCancelsQuitVisiblyAndRetryExitsAfterSaving`, `testSlowNetworkJoinNeverCancelsAQuitWhoseLocalWorkSaved`, `testQuitDuringPublisherPassJoinsItWithinBudgetAndStartsNoNewPass` and `testQuitProceedsWhenPublisherPassNeverFinishesBecauseTheJoinIsBounded`. A real Cmd-Q is attended `make native-ui` evidence and has not been run.

### W-INV-020 — A store migration takes a backup first and refuses to lose a populated table
area: ["Producer/Sources/WiltedProducer/LocalLibrary/**", "Producer/Tests/WiltedProducerTests/LocalLibraryStoreCompatibilityTests.swift", "docs/statistics-migration-recovery.md"]
gate_test: test-gate.sh
threshold: 3
rationale: Opening an older store checkpoints its WAL, migrates a disposable clone and compares row counts, then copies the main file and every sidecar to a retained backup before migrating in place and verifying counts again. A table that held rows must exist afterwards with the same count; an empty table that vanishes is not data loss and new tables are fine. A failure restores the original from the backup and throws; a store newer than this build, or unrecognised, is refused before any write, and `migrate: false` never migrates. Backups are never deleted automatically. Enforced by `testRowCountVerificationRejectsMissingTablesAndAcceptsAddedOnes`, `testV13FixtureMigratesToV14WithRetainedBackupAndReopens`, `testFailureAfterInPlaceMigrationRestoresTheV13Original`, `testRetainedBackupRestoreProcedureReturnsTheV13Store`, `testV13StoreWithLiveWALIsCheckpointedIntoACompleteBackup`, `testV13FixtureIsRefusedUnmodifiedWithoutMigration` and `testNewerStoreIsRefusedWithoutAnyWrite`. Only fixture copies have been migrated; no real library has.

### W-INV-021 — Library sends are held on an account change until the owner reviews it
area: ["WiltedMac/Sync/WiltedMacLibraryAccountGate.swift", "WiltedMac/Sync/WiltedMacLibraryAccountState.swift", "WiltedMac/Sync/WiltedMacLibraryPublisher.swift", "WiltedMacTests/WiltedMacLibraryAccountTests.swift", "WiltedMacTests/WiltedMacLibrarySyncStatusTests.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: The library publisher is bound to one iCloud account owner and sends nothing until the current account is the bound owner. An empty library binds its first owner without review; a library with data and no binding needs approval, even after relaunch; a sign-out or a different account holds sending until the owner approves in Settings, and a delayed fetch or send that completes after the change commits nothing. With no account, an unavailable check, a failed binding or a transport that cannot report accounts, nothing is sent and the status says why. Status text and logs never carry a raw account identifier or token, and no held state offers Sync now. Enforced by `testFirstOwnerOfAnEmptyLibraryBindsAndSurvivesRelaunchWithoutReview`, `testUnboundLibraryWithDataNeedsApprovalEvenAfterRelaunch`, `testADifferentAccountIsRetainedAsAConflictUntilApproved`, `testDelayedSendAfterAnAccountChangeCommitsNothingAndLaterSendsNeverLeave`, `testDelayedFetchAfterAnAccountChangeWritesNothing`, `testACheckThatFindsNoAccountKeepsSendingClosedWithAClearStatus`, `testAccountLogsAndStatusCarryNoRawIdentifierOrToken`, `testEveryAccountHoldHasPlainCopyAndNeverOffersSyncNow` and `testAccountReviewCopyAndApprovalThroughTheRealOwner`. Behavior against a live iCloud account is unverified.

### W-INV-022 — Deletion needs confirmation and keeps downloaded files
area: ["WiltedMac/ViewModel/**", "Producer/Sources/WiltedProducer/LocalLibrary/**", "WiltedMacTests/WiltedMacDeletionSafetyTests.swift", "Producer/Tests/WiltedProducerTests/LocalLibraryStoreTests+DeletionSafety.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: Unsubscribing from a feed and removing an article on the Mac each wait for confirmation. A cancelled confirmation writes nothing and playback continues. A confirmed unsubscribe removes only that feed's records, stops its audio and leaves downloaded audio files on disk; a confirmed article delete commits once and clears the player. A failure at any stage leaves rows, the player, the listening queue and media unchanged, and a repeated delete writes once. Enforced by `testCancelledUnsubscribeWritesNothingAndKeepsPlaying`, `testConfirmedUnsubscribeRemovesOnlyThatFeedAndStopsItsAudio`, `testEveryFailedUnsubscribeStageKeepsRowsPlayerAndRecords`, `testCancelledArticleDeleteWritesNothing`, `testConfirmedDeleteOfTheCurrentArticleCommitsOnceAndClearsThePlayer` and `testEveryFailedArticleStageKeepsSelectionPlayerAndRecords` (`WiltedMacDeletionSafetyTests`), and `testUnsubscribeFailureAtEachStageLeavesRowsListeningQueueAndMediaUnchanged` and `testDuplicateUnsubscribeWritesOnce` (`LocalLibraryStoreTests+DeletionSafety`).
