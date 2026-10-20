import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif


extension WiltedMacModel {
#if canImport(WiltedProducer)
#if canImport(WiltedProducer)
    /// The journal keys each status as `requestID|stage#ordinal`, and the stage it
    /// stores is the coarse one every pipeline shares, so the worker's own
    /// stage name survives only in the key.
    nonisolated static func processorEvents(for run: PreparationRunSummary) -> [WiltedMacProcessorEvent] {
        run.entries.map { entry in
            let prefix = run.requestID + "|"
            let storedStage = entry.id.hasPrefix(prefix) ? String(entry.id.dropFirst(prefix.count)) : entry.status.stage.rawValue
            let stage = storedStage.split(separator: "#").first.map(String.init) ?? storedStage
            return WiltedMacProcessorEvent(
                id: entry.id, at: entry.status.emittedAt.date, stage: stage,
                detail: entry.status.detail, fraction: entry.status.fraction
            )
        }
    }

    /// A running podcast run is narrated from its latest worker stage; a
    /// finished one, and every article run, from what the journal recorded.
    nonisolated static func processorNarrative(
        isPodcast: Bool, outcome: WiltedMacProcessorRun.Outcome, detail: String, events: [WiltedMacProcessorEvent]
    ) -> String {
        guard isPodcast, outcome == .running, let latest = events.last(where: { !$0.stage.hasPrefix("log.") }) else {
            return detail
        }
        return preparationLabel(for: PodcastPreparationProgress(stage: latest.stage, detail: latest.detail))
    }
#endif

#if canImport(WiltedProducer)
    /// The launch storage-sweep log. A sweep that throws is not silent: it
    /// lands here at `.warning`, retrievable with
    /// `log show --predicate 'subsystem BEGINSWITH "com.zerodelta.wilted" AND processImagePath BEGINSWITH "/Applications/"'`.
    private static let reclaimLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Reclaim")

    func performStoreBootstrap() async {
        let retainedPathsBeforeAttempt = await Task.detached { [libraryURL] in
            Set(Self.recoveryCopyURLs(for: libraryURL).map(\.path))
        }.value
        do {
            let configuredStore = try await storeBootstrap(libraryURL)
            configureStoreDependencies(configuredStore)
            // Must run before any V10-aware read path below, and specifically
            // before `invalidateStalePodcastPreparations`: reconcile's own
            // timestamp-ordering guard assumes it sees legacy markers before
            // this launch's invalidation pass writes new ones.
            announceStartupStep(.updatingLibraryFormat)
            try await configuredStore.reconcilePodcastStateV10()
            // Before the completion sweep below: a V12 store's pre-migration
            // retirements carry a bare `retiredAt` with no `removalKind` yet,
            // which is exactly the shape the sweep's own guard is looking
            // for. Folding the tombstone table onto `removalKind` first keeps
            // an already-retired row out of the sweep, so its original
            // timestamp is not clobbered with this launch's.
            _ = try? await configuredStore.reconcileEpisodeRemovals()
            // After reconcile, so this sees the listening rows step 2 just
            // backfilled from legacy playback records, and before the
            // library is read, so retirement is reflected in the first
            // `loadLibrary` rather than appearing a moment later.
            announceStartupStep(.retiringFinishedEpisodes)
            try await configuredStore.retireCompletedEpisodesMissingRetirement()
            let invalidation: PodcastPreparationInvalidationResult
            if requiresLaunchFingerprintResolution {
                // The step is announced before the await, so the readout names
                // fingerprinting while resolution is still in flight rather than
                // after it finishes.
                announceStartupStep(.checkingPreparationFingerprint)
                if let fingerprint = await pipelineFingerprintResolution() {
                    do {
                        invalidation = try await invalidateStalePreparations(configuredStore, fingerprint)
                    } catch {
                        // The store opened and the library is intact; only the
                        // stale-preparation pass failed, and that is its own
                        // condition rather than "could not open your larder".
                        throw WiltedMacStaleInvalidationFailure(underlying: error)
                    }
                } else {
                    // Missing or unreadable pipeline sources are not evidence of a
                    // semantic change. Preserve every preparation until a complete
                    // fingerprint can be resolved on a later launch.
                    invalidation = PodcastPreparationInvalidationResult()
                }
            } else {
                // No rule can condemn a preparation and no invalidator was
                // substituted, so there is no comparison to make and opening
                // the library must not hash the worker and Python trees for an
                // empty rule set. Markers an earlier launch already wrote are
                // scheduling state, though: this launch still has to admit
                // their recovery. Project them without resolving a fingerprint
                // or deciding anything again.
                invalidation = try await configuredStore.pendingPreparationRecoveryIDs()
            }
            // Before the library is read, so the rows derive from a journal
            // that tells the truth about what is running: nothing, yet.
            announceStartupStep(.closingInterruptedRuns)
            await closeInterruptedPreparationRuns(in: configuredStore)
            // After the close, so the journal already says failed and the
            // ticket queue agrees rather than contradicts it; before the
            // library load, so the first rows drawn are already reconciled.
            announceStartupStep(.reconcilingWork)
            let ticketReconciliation = await reconcileWorkTickets(in: configuredStore)
            // The launch storage sweep: exactly one directory, the downloaded
            // episode audio itself -- never `<media>` whole, the preparation
            // work directory, or the aligned-STT cache. The player has not
            // been restored yet, so the store's queue state is the source for
            // the file playback is about to open, and that file is excluded
            // rather than assumed. A throwing sweep never blocks launch: the
            // library is intact and the next launch sweeps again.
            announceStartupStep(.reclaimingStorage)
            // No download is in flight this early, so any `<UUID>.<ext>` left in
            // the staging directory belongs to a process that died mid-transfer.
            let staging = await Task.detached { [mediaDirectory] in
                Self.removeAbandonedDownloadStaging(in: mediaDirectory)
            }.value
            Self.logStagingCleanup(staging)
            // Nothing prepares this early either, so a prepared copy, a worker's
            // render file or an encode temp left in `<media>` belongs to a run
            // that crashed or failed. Named files only; a failure never blocks launch.
            do {
                Self.logPreparationScratchCleanup(
                    try await configuredStore.removeAbandonedPreparationScratch(in: mediaDirectory)
                )
            } catch {
                Self.reclaimLog.warning(
                    "preparation scratch cleanup failed: \(LogSafeError.describe(error), privacy: .public)"
                )
            }
            var storageSweepErrors: [String] = []
            do {
                let report = try await reclaimStorage(
                    configuredStore,
                    [mediaDirectory.appendingPathComponent("PodcastAudio", isDirectory: true)],
                    await currentPlaybackMediaExclusions(in: configuredStore)
                )
                Self.logSweepOutcome(report)
            } catch {
                Self.reclaimLog.warning(
                    "storage sweep failed: \(LogSafeError.describe(error), privacy: .public)"
                )
                storageSweepErrors = ["storage: \(LogSafeError.describe(error))"]
            }
            let ticketErrors = ticketReconciliation.errors.map { "\($0.subjectID): \($0.message)" }
            if !ticketErrors.isEmpty {
                Self.reclaimLog.warning(
                    "startup recovery left \(ticketErrors.count) unfinished: \(LogSafeError.scrubbingURLs(ticketErrors.joined(separator: "; ")), privacy: .public)"
                )
            }
            if ticketErrors.isEmpty, storageSweepErrors.isEmpty {
                announceStartupStep(.loadingLibrary)
            } else if ticketErrors.isEmpty {
                announceStartupStep(.recoveringWork(
                    action: "continuing without reclaiming storage",
                    done: 0,
                    total: 0,
                    errors: storageSweepErrors
                ))
            } else {
                announceStartupStep(.recoveringWork(
                    action: "continuing with recovered requests",
                    done: ticketReconciliation.totalCount,
                    total: ticketReconciliation.totalCount,
                    errors: ticketErrors + storageSweepErrors
                ))
            }
            let library = try await loadLibrary(from: configuredStore)
            articles = library.articles
            applyEpisodes(library.episodes, allowsAutomaticAdmissions: false)
            subscriptions = library.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: configuredStore)
            // A deferred job predating a forced redownload must never start on
            // the stale prepared file while its replacement is being fetched.
            for itemID in Set(invalidation.resetEpisodeIDs + invalidation.forcedRedownloadEpisodeIDs) {
                removeDeferredAutomaticPreparation(itemID.rawValue)
            }
            // Pipeline invalidation is a library-wide migration, not a row-by-row
            // recovery chore. Re-admit every intact source through the current
            // processing policy; manual stays manual, while immediate and
            // off-peak policies resume without the owner finding each episode.
            restoreDeferredAutomaticPreparations()
            for itemID in invalidation.resetEpisodeIDs {
                guard let episode = episodes.first(where: { $0.id == itemID.rawValue }) else { continue }
                admitAutomaticPreparation(for: episode, at: Date())
            }
            // Bootstrap recovery is a burst of redownloads discovered at once,
            // not one the owner asked for -- admitted one at a time so a
            // library-wide pipeline migration cannot open N simultaneous
            // transfers. A deliberate download from the row is unaffected;
            // this task only serializes the automatic recovery batch. It runs
            // detached from startup so a migration with many stale episodes
            // cannot hold the app in a non-ready state for the whole burst.
            let forcedRedownloadEpisodeIDs = invalidation.forcedRedownloadEpisodeIDs
            if !forcedRedownloadEpisodeIDs.isEmpty {
                bootstrapRecoveryTask?.cancel()
                bootstrapRecoveryTask = Task { [weak self] in
                    guard let self else { return }
                    for itemID in forcedRedownloadEpisodeIDs {
                        guard !Task.isCancelled else { return }
                        guard let episode = self.episodes.first(where: { $0.id == itemID.rawValue }) else { continue }
                        self.downloadEpisode(episode, ignoringExisting: true, automaticRecovery: true)
                        if let task = self.podcastDownloadTasks[episode.id] {
                            _ = try? await task.value
                        }
                    }
                }
            }
            // `.retryable` failures resume through the coordinator's own
            // cache/resume logic, not a forced fresh fetch -- the failure was
            // a transport hiccup, not evidence the prior bytes are wrong.
            // Queued through `unfinishedAutomationClaims` below (via
            // `startAutomationOnLaunch`'s reconcile) rather than started here
            // directly: bootstrap starting N of these concurrently would
            // contradict the serial, one-at-a-time queue automation is meant
            // to be the only path through.
            announceStartupStep(.restoringPlayback)
            await restorePodcastPlayback()
            await restorePendingPodcastPreparations(in: configuredStore,
                excluding: Set(invalidation.forcedRedownloadEpisodeIDs.map(\.rawValue)))
            startupState = .ready
            // The query restored at launch could not search transcripts before the store existed.
            scheduleTranscriptSearch()
            // After `.ready`: the summary is observed state, so a slow, failed
            // or rebuilding one never holds the larder closed or fails it.
            beginLifetimeStatisticsLoad()
            // After the library is in memory, not in a parallel task: automation
            // resolves a claimed episode ID against `episodes`.
            startAutomationOnLaunch()
            startAutomationTicker()
            startPlaybackCheckpointTicker()
            startTicketDrainTicker()
            startLibrarySyncIfEnabled()
        } catch let invalidationFailure as WiltedMacStaleInvalidationFailure {
            configureStoreDependencies(nil)
            startupState = .failed(WiltedMacStartupFailure(
                message: Self.staleInvalidationFailureMessage,
                detail: LogSafeError.describe(invalidationFailure.underlying),
                recoveryCopyURL: nil,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        } catch {
            configureStoreDependencies(nil)
            // A failed migration names its own backup; only other failures
            // fall back to whichever retained copy this attempt created.
            let recoveryURL: URL?
            if let typedBackupURL = Self.migrationBackupURL(from: error) {
                recoveryURL = typedBackupURL
            } else {
                recoveryURL = await Task.detached { [libraryURL, retainedPathsBeforeAttempt] in
                    Self.recoveryCopyURLs(for: libraryURL).first {
                        !retainedPathsBeforeAttempt.contains($0.path)
                    }
                }.value
            }
            startupState = .failed(WiltedMacStartupFailure(
                message: Self.storeOpenFailureMessage(for: error),
                detail: LogSafeError.describe(error),
                recoveryCopyURL: recoveryURL,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        }
        startupTask = nil
    }

    /// The current playback episode's on-disk audio, excluded from the launch
    /// sweep. The player has not been restored at this point, so the store is
    /// the source: the completed download's file and the ready revision's
    /// media are both excluded when present, so the episode the listener is
    /// about to resume keeps its bytes.
    private func currentPlaybackMediaExclusions(in store: LocalLibraryStore) async -> Set<URL> {
        guard let currentEpisodeID = try? await store.podcastQueueState().currentEpisodeID else {
            return []
        }
        var exclusions: Set<URL> = []
        if let download = try? await store.download(for: currentEpisodeID), let localURL = download.localURL {
            exclusions.insert(localURL)
        }
        if let revision = try? await store.readyRevision(for: currentEpisodeID) {
            exclusions.insert(revision.mediaURL)
        }
        return exclusions
    }

    /// The stale-preparation failure's copy, separate from a store that will
    /// not open: the library is intact and only the version check failed.
    nonisolated static let staleInvalidationFailureMessage =
        "Wilted could not check your preparations against this build. The existing library was left in place."

    /// The backup a failed migration reports for itself, when the error is one.
    nonisolated static func migrationBackupURL(from error: Error) -> URL? {
        guard let storeError = error as? LocalLibraryStoreError else { return nil }
        switch storeError {
        case let .migrationFailedRestored(backupURL, _), let .migrationRestoreFailed(backupURL, _):
            return backupURL
        default:
            return nil
        }
    }

    /// The headline for a store that would not open. Only a failed restore
    /// says the library is not in place: that is the one case where it is not.
    nonisolated static func storeOpenFailureMessage(for error: Error) -> String {
        if let storeError = error as? LocalLibraryStoreError, case .migrationRestoreFailed = storeError {
            return "Wilted could not restore your previous library after a failed update. "
                + "Restore the recovery copy by hand before Wilted can open your larder."
        }
        return "Wilted could not open your larder. The existing library was left in place."
    }

    /// Removes the `<UUID>.<ext>` files a download left in
    /// `<media>/.podcast-staging/` when its process died before the
    /// coordinator's own cleanup ran. Looks only at regular files directly in
    /// that directory; nothing else under `media` is read or removed, and no
    /// failure escapes: it is counted so the launch can log it and go on.
    nonisolated static func removeAbandonedDownloadStaging(in mediaDirectory: URL) -> (removed: Int, failed: Int) {
        let manager = FileManager.default
        let staging = mediaDirectory.appendingPathComponent(".podcast-staging", isDirectory: true)
        // A staging directory that is itself a link would point the removals elsewhere.
        guard let stagingValues = try? staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              stagingValues.isDirectory == true, stagingValues.isSymbolicLink != true,
              let entries = try? manager.contentsOfDirectory(
                  at: staging, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
              ) else { return (0, 0) }
        var removed = 0
        var failed = 0
        for entry in entries {
            guard !entry.pathExtension.isEmpty,
                  UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            do {
                try manager.removeItem(at: entry)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    private static func logStagingCleanup(_ outcome: (removed: Int, failed: Int)) {
        if outcome.failed > 0 {
            reclaimLog.warning(
                "download staging cleanup removed=\(outcome.removed) failedRemovals=\(outcome.failed)"
            )
        } else if outcome.removed > 0 {
            reclaimLog.notice("download staging cleanup removed=\(outcome.removed)")
        }
    }

    private static func logPreparationScratchCleanup(_ sweep: PreparationScratchSweep) {
        if sweep.failed > 0 || sweep.skippedLiveWorker {
            reclaimLog.warning(
                "preparation scratch cleanup removed=\(sweep.removed) bytes=\(sweep.bytes) failedRemovals=\(sweep.failed) liveWorker=\(sweep.skippedLiveWorker)"
            )
        } else if sweep.removed > 0 {
            reclaimLog.notice("preparation scratch cleanup removed=\(sweep.removed) bytes=\(sweep.bytes)")
        }
    }

    /// Logs one sweep at a level that persists: a skipped or partly failed
    /// sweep at `.warning` with the reason, a clean one at `.notice`.
    private static func logSweepOutcome(_ report: MediaSweepReport) {
        if let skipped = report.skipped {
            let reason: String
            switch skipped {
            case let .storedPathOutsideLibrary(count):
                reason = "storedPathOutsideLibrary count=\(count)"
            case .noReferencedFileFound:
                reason = "noReferencedFileFound"
            }
            reclaimLog.warning("storage sweep skipped: \(reason, privacy: .public)")
        }
        if report.failedRemovals > 0 {
            reclaimLog.warning(
                "storage sweep removed files=\(report.files) bytes=\(report.bytes) failedRemovals=\(report.failedRemovals)"
            )
        }
        if report.skipped == nil, report.failedRemovals == 0 {
            reclaimLog.notice(
                "storage sweep removed files=\(report.files) bytes=\(report.bytes) clearedRecords=\(report.clearedRecords)"
            )
        }
    }

    /// Closes every run the journal still calls live.
    ///
    /// Found 2026-09-05: an install quit Wilted while an episode was
    /// preparing. The pipeline journals a run's terminal entry from inside
    /// the run, so a run that dies with its process never gets one, and on
    /// the next launch the row read "Preparing…" with nothing behind it and
    /// a Stop that stopped nothing. Every run belongs to the process that
    /// started it, and this process has started none, so a run the journal
    /// calls live at bootstrap is an interrupted one. It is closed as failed
    /// with the reason, which puts it on Prep beside a retry, where every
    /// other failure goes.
    private func closeInterruptedPreparationRuns(in store: LocalLibraryStore) async {
        guard let runs = try? await store.preparationRuns() else { return }
        for run in runs where !run.isTerminal {
            if run.entries.first?.status.attempt != nil,
               (try? await store.closeInactivePreparationRun(run, at: Timestamp(Date()),
                    detail: Self.preparationInterruptedMessage)) == true { continue }
            // An outcome durable for this episode's ready revision and dated
            // at or after this run's own start is proof this run itself
            // finished and saved before the process died -- only the
            // terminal journal write was interrupted. Stamping `.failed` over
            // that would hide a proven artifact behind a false failure. An
            // outcome from an older run (dated before this one started)
            // proves nothing about this run, which is left to close normally.
            if let readyRevisionID = try? await store.readyRevision(for: run.itemID)?.revision.revisionID,
               let outcome = try? await store.preparationOutcome(for: run.itemID, revisionID: readyRevisionID),
               outcome.producedAt >= run.startedAt {
                continue
            }
            guard let entry = Self.interruptedPreparationEntry(for: run, at: Timestamp(Date())) else { continue }
            try? await store.record(preparation: entry)
        }
    }

    /// What Prep says about a run its process did not live to finish.
    nonisolated static let preparationInterruptedMessage =
        "Wilted quit while this was preparing. Retry it from Larder."

    /// The terminal entry that closes an interrupted run, or nil for a run
    /// that already has one.
    nonisolated static func interruptedPreparationEntry(
        for run: PreparationRunSummary, at emittedAt: Timestamp
    ) -> PreparationJournalEntry? {
        guard !run.isTerminal,
              let error = try? ProducerError(code: .failed, message: preparationInterruptedMessage,
                                             retryable: true, stage: "interrupted"),
              let terminal = try? PreparationTerminalResult(outcome: .failed, error: error),
              let status = try? PreparationStatus(stage: .failed, detail: preparationInterruptedMessage,
                                                  cancellable: false, terminalResult: terminal,
                                                  emittedAt: max(emittedAt, run.entries.last?.status.emittedAt ?? run.updatedAt),
                                                  attempt: run.entries.first?.status.attempt)
        else { return nil }
        let generation = status.attempt.map { $0.key + "|" } ?? ""
        return PreparationJournalEntry(
            id: run.requestID + "|" + generation + "interrupted", itemID: run.itemID, requestID: run.requestID, status: status
        )
    }

    /// Drives the store's idempotent work-ticket bootstrap and, only after it
    /// saves without throwing, deletes the preferences this launch imported
    /// from. Deleting first would lose the deferrals if the save failed;
    /// deleting only after a clean return means a failed pass leaves the
    /// preferences in place for the next launch to import again, which the
    /// store's own find-or-insert makes harmless.
    ///
    /// `deferredAutomaticPreparations` and `preparationRequestSequence` are
    /// already the in-memory values loaded from preferences at `init` --
    /// this does not re-read preferences, it just crosses what init already
    /// read into the store actor's vocabulary.
    ///
    /// After the store's own idempotent pass returns, `preparationRequestSequences`
    /// and `preparationRequestSequence` are rebuilt from `store.workTickets()`
    /// -- the ticket table, not this launch's preferences -- which is what
    /// lets a request still pending at relaunch keep its number and its
    /// place: rebuilding here, after the store's import/adopt steps above,
    /// means an imported deferral or an in-memory request carried over from
    /// this same launch (the store-less fallback below) is already a row by
    /// the time the projection reads it back.
    func reconcileWorkTickets(in store: LocalLibraryStore) async -> WorkTicketReconciliation {
        let encoder = JSONEncoder()
        var importedDeferrals = deferredAutomaticPreparations.map { job in
            WorkTicketImportedDeferral(
                subjectID: job.episodeID,
                policySnapshot: try? encoder.encode(job.policySnapshot),
                processingPolicy: try? encoder.encode(job.processingPolicy)
            )
        }
        // The store-less fallback: a preparation request issued while `store`
        // was nil (or before this launch's bootstrap reached this point) has
        // only ever lived in `preparationRequestSequences`, in memory. Rather
        // than lose it outright, it is carried into the next successful
        // reconcile as an imported deferral, same as a preferences-held
        // off-peak job -- degrading to "picked up a beat late" instead of
        // "silently dropped". `WorkTicketImportedDeferral` only knows one
        // kind (`.podcastPreparation`, matching `reconcileWorkTickets`'s own
        // step 1); an article request carried this way would be misclassified,
        // but a store-less model never reaches `addArticle`'s admission point
        // at all (it returns at the coordinator guard), so no article subject
        // can appear in this dictionary in practice.
        let alreadyImported = Set(deferredAutomaticPreparations.map(\.episodeID))
        for subjectID in preparationRequestSequences.keys where !alreadyImported.contains(subjectID) {
            importedDeferrals.append(WorkTicketImportedDeferral(subjectID: subjectID))
        }
        do {
            let reconciliationAttempt = startupAttemptCount
            let reconciliation = try await store.reconcileWorkTickets(
                now: Timestamp(Date()), sequenceFloor: preparationRequestSequence,
                importedDeferrals: importedDeferrals,
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.startupAttemptCount == reconciliationAttempt,
                              self.startupState.loadingStep?.acceptsWorkTicketRecoveryProgress == true else { return }
                        self.announceStartupStep(.recoveringWork(
                            action: update.step.startupAction, done: update.done, total: update.total
                        ))
                    }
                }
            )
            preferences.removeObject(forKey: Self.deferredAutomaticPreparationsPreferenceKey)
            preferences.removeObject(forKey: Self.preparationRequestSequencePreferenceKey)

            guard let tickets = try? await store.workTickets() else { return reconciliation }
            preparationRequestSequence = max(preparationRequestSequence, tickets.map(\.requestSequence).max() ?? 0)
            preparationRequestSequences = tickets
                .filter { ($0.kind == .podcastPreparation || $0.kind == .articlePreparation)
                    && ($0.state == .pending || $0.state == .deferred) }
                .reduce(into: [String: Int]()) { result, ticket in result[ticket.subjectID] = ticket.requestSequence }
            return reconciliation
        } catch is CancellationError {
            return WorkTicketReconciliation(
                importedDeferralCount: 0, adoptedDownloadCount: 0, closedRunCount: 0, prunedCount: 0
            )
        } catch {
            return WorkTicketReconciliation(
                importedDeferralCount: 0, adoptedDownloadCount: 0, closedRunCount: 0, prunedCount: 0,
                errors: [LocalLibraryStore.WorkTicketReconciliationError(
                    step: .importingDeferrals, subjectID: "work-ticket-recovery", message: LogSafeError.describe(error)
                )]
            )
        }
    }

    func configureStoreDependencies(_ configuredStore: LocalLibraryStore?) {
        store = configuredStore
        coordinator = configuredStore.map {
            PreparationCoordinator(store: $0, mediaDirectory: mediaDirectory)
        }
        playback = configuredStore.map {
            PlaybackController(
                store: $0,
                backend: Self.playbackBackend(fixtureMode: fixtureMode),
                deviceID: "mac"
            )
        }
        // Pause when the speakers or headphones go away, as the iPhone does.
        // Fixtures and test hosts never register CoreAudio listeners.
        if !fixtureMode, !Self.hostsTests { playback?.enableOutputLossPause() }
        playback?.onOutputLostPause = { [weak self] in self?.refreshPlaybackReadout() }
        playback?.automaticPodcastQueueAdvancePredicate = { [weak self] itemID in
            // Books retain their existing queue completion policy. Podcasts use Ready order.
            self?.episodes.first(where: { $0.id == itemID.rawValue })?.isAudiobook == true
        }
        playback?.defaultRate = Float(playbackRate)
        playback?.episodeEligibilityPredicate = { [weak self] itemID in
            guard let self else { return false }
            guard let episode = self.episodes.first(where: { $0.id == itemID.rawValue }) else { return false }
            // An imported book has no preparation outcome in the store, which is what the controller's
            // own fallback checks, so the loaded row answers for it: not removed, and its joined file on
            // disk. Without this branch a book that survived a reload could not start from the queue.
            if episode.isAudiobook {
                return !self.hiddenEpisodeIDs.contains(episode.id) && episode.retiredAt == nil
                    && episode.removalKind == nil && episode.isReadyMediaAvailable
            }
            return self.canPlayEpisode(episode)
        }
        playback?.podcastStateHandler = { [weak self] itemID, fault in
            self?.applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
        }
        // Retire every durable podcast completion, once. A natural end's
        // retirement waits behind the successor's start (`libraryFollowUps`);
        // this handler does not mutate queue membership while the controller
        // is checkpointing.
        playback?.podcastCompletionHandler = { [weak self] episodeID in
            self?.retireDurablePodcastCompletion(episodeID)
        }
        // The controller's Mac policy stops at every natural podcast end so
        // the model can choose the first Ready row, including earlier entries.
        // Playlist and non-podcast completion remain guarded by the model.
        playback?.podcastNaturalCompletionHandlerFactory = { [weak self] itemID in
            self?.naturalPodcastEndHandler(for: itemID)
        }
        playback?.playbackDidFinishHandler = { [weak self] in
            guard let self else { return }
            // Podcasts use the EOF-captured owner; the legacy observer still handles playlist ends.
            if self.playlistSessionIsCurrent || !self.isPodcastPlayback {
                self.handlePodcastPlaybackFinished()
            }
        }
        let resolvedPodcastDownloadTransportFactory: WiltedMacPodcastDownloadTransportFactory?
        if let podcastDownloadTransportFactory {
            resolvedPodcastDownloadTransportFactory = podcastDownloadTransportFactory
        } else if fixtureMode {
            // The fixture retry must reuse one scripted transport. Creating a
            // fresh transport per coordinator request reset its one failure,
            // so Retry could never reach the successful offline state.
            let transport = WiltedFixturePodcastDownloadTransport(
                failuresRemaining: fixtureDownloadFailuresRemaining
            )
            resolvedPodcastDownloadTransportFactory = {
                transport
            }
        } else {
            resolvedPodcastDownloadTransportFactory = nil
        }
        let resolvedPodcastMediaValidatorFactory: WiltedMacPodcastMediaValidatorFactory?
        if let podcastMediaValidatorFactory {
            resolvedPodcastMediaValidatorFactory = podcastMediaValidatorFactory
        } else if fixtureMode {
            resolvedPodcastMediaValidatorFactory = { WiltedFixturePodcastMediaValidator() }
        } else {
            resolvedPodcastMediaValidatorFactory = nil
        }
        podcastDownloadCoordinator = configuredStore.map { store in
            switch (resolvedPodcastDownloadTransportFactory, resolvedPodcastMediaValidatorFactory) {
            case let (transportFactory?, validatorFactory?):
                PodcastDownloadCoordinator(
                    store: store, libraryDirectory: mediaDirectory,
                    transport: transportFactory(), mediaValidator: validatorFactory()
                )
            case let (transportFactory?, nil):
                PodcastDownloadCoordinator(store: store, libraryDirectory: mediaDirectory, transport: transportFactory())
            case let (nil, validatorFactory?):
                PodcastDownloadCoordinator(store: store, libraryDirectory: mediaDirectory, mediaValidator: validatorFactory())
            case (nil, nil):
                PodcastDownloadCoordinator(store: store, libraryDirectory: mediaDirectory)
            }
        }
        podcastPreparationPipeline = fixtureMode ? nil : configuredStore.map { store in
            if let podcastPipelineRunnerFactory {
                return PodcastPreparationPipeline(
                    store: store,
                    workDirectory: mediaDirectory.appendingPathComponent("preparation", isDirectory: true),
                    runner: podcastPipelineRunnerFactory(),
                    removeAds: removesAdvertisements
                )
            }
            return PodcastPreparationPipeline(
                store: store,
                workDirectory: mediaDirectory.appendingPathComponent("preparation", isDirectory: true),
                removeAds: removesAdvertisements
            )
        }
        if configuredStore != nil, !fixtureMode { startMorningReportSchedule() }
    }

    private func restorePodcastPlayback() async {
        guard let playback else { return }
        let selectionToken = playbackCommands.selectionToken
        playbackOperationStatus = "Restoring Larder…"
        isRestoringPodcastPlayback = true
        await playback.restorePodcastQueue()
        await refreshPodcastQueueState()
        let restoredQueueState = try? await store?.podcastQueueState()
        let restoredOrigin = restoredQueueState.flatMap { restoredPodcastPlaybackOrigin(for: $0) }
        guard playbackCommands.selectionToken == selectionToken, !isClosingTemporaryState else {
            isRestoringPodcastPlayback = false
            return
        }
        if let itemID = playback.itemID,
           episodes.contains(where: { $0.id == itemID.rawValue }) {
            currentPodcastEpisodeID = itemID.rawValue
            selectedArticleID = nil
            isPodcastPlayback = true
            // Missing or stale records retain the legacy generic continuation.
            isLarderQueuePlayback = restoredOrigin ?? false
            isNowPlaying = true
            refreshPlaybackReadout()
            requestPlaybackPresentation(itemID: itemID, includesCuts: true)
            isRestoringPodcastPlayback = false
            if let restoredQueueState { persistPodcastPlaybackOrigin(for: restoredQueueState) }
        } else {
            isRestoringPodcastPlayback = false
        }
        playbackOperationStatus = nil
    }

#endif
#endif
}
