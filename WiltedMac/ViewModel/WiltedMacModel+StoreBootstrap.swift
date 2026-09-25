import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
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
    func performStoreBootstrap() async {
        let retainedPathsBeforeAttempt = await Task.detached { [libraryURL] in
            Set(Self.retainedV5StoreURLs(for: libraryURL).map(\.path))
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
            // The account-review gate is durable state, so restore it before
            // the ready surface can expose sync controls.
            syncLifecycle?.restoreAccountQuarantine()
            // Before the library is read, so the rows derive from a journal
            // that tells the truth about what is running: nothing, yet.
            announceStartupStep(.closingInterruptedRuns)
            await closeInterruptedPreparationRuns(in: configuredStore)
            // After the close, so the journal already says failed and the
            // ticket queue agrees rather than contradicts it; before the
            // library load, so the first rows drawn are already reconciled.
            announceStartupStep(.reconcilingWork)
            await reconcileWorkTickets(in: configuredStore)
            announceStartupStep(.loadingLibrary)
            let library = try await loadLibrary(from: configuredStore)
            articles = library.articles
            episodes = library.episodes
            subscriptions = library.subscriptions
            lifetimeStatistics = try await configuredStore.lifetimeStatistics()
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
                        self.downloadEpisode(episode, ignoringExisting: true)
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
            startupState = .ready
            if pendingSyncReconciliation {
                pendingSyncReconciliation = false
                reconcileSyncOnLaunchOrForeground()
            }
            // After the library is in memory, not in a parallel task: automation
            // resolves a claimed episode ID against `episodes`.
            startAutomationOnLaunch()
            startAutomationTicker()
            startPlaybackCheckpointTicker()
            startTicketDrainTicker()
        } catch let invalidationFailure as WiltedMacStaleInvalidationFailure {
            configureStoreDependencies(nil)
            startupState = .failed(WiltedMacStartupFailure(
                message: Self.staleInvalidationFailureMessage,
                detail: String(describing: invalidationFailure.underlying),
                retainedV5StoreURL: nil,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        } catch {
            configureStoreDependencies(nil)
            let retainedURL = await Task.detached { [libraryURL, retainedPathsBeforeAttempt] in
                Self.retainedV5StoreURLs(for: libraryURL).first {
                    !retainedPathsBeforeAttempt.contains($0.path)
                }
            }.value
            startupState = .failed(WiltedMacStartupFailure(
                message: "Wilted could not open your larder. The existing library was left in place.",
                detail: String(describing: error),
                retainedV5StoreURL: retainedURL,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        }
        startupTask = nil
    }

    /// The stale-preparation failure's copy, separate from a store that will
    /// not open: the library is intact and only the version check failed.
    nonisolated static let staleInvalidationFailureMessage =
        "Wilted could not check your preparations against this build. The existing library was left in place."

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
                                                  cancellable: false, terminalResult: terminal, emittedAt: emittedAt)
        else { return nil }
        return PreparationJournalEntry(
            id: run.requestID + "|interrupted", itemID: run.itemID, requestID: run.requestID, status: status
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
    func reconcileWorkTickets(in store: LocalLibraryStore) async {
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
            _ = try await store.reconcileWorkTickets(
                now: Timestamp(Date()), sequenceFloor: preparationRequestSequence,
                importedDeferrals: importedDeferrals
            )
        } catch {
            return
        }
        preferences.removeObject(forKey: Self.deferredAutomaticPreparationsPreferenceKey)
        preferences.removeObject(forKey: Self.preparationRequestSequencePreferenceKey)

        guard let tickets = try? await store.workTickets() else { return }
        preparationRequestSequence = max(preparationRequestSequence, tickets.map(\.requestSequence).max() ?? 0)
        preparationRequestSequences = tickets
            .filter { ($0.kind == .podcastPreparation || $0.kind == .articlePreparation)
                && ($0.state == .pending || $0.state == .deferred) }
            .reduce(into: [String: Int]()) { result, ticket in result[ticket.subjectID] = ticket.requestSequence }
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
        playback?.defaultRate = Float(playbackRate)
        playback?.episodeEligibilityPredicate = { [weak self] itemID in
            guard let self else { return false }
            guard let episode = self.episodes.first(where: { $0.id == itemID.rawValue }) else { return false }
            return self.canPlayEpisode(episode)
        }
        playback?.podcastStateHandler = { [weak self] itemID, fault in
            self?.applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
        }
        // Fires for every podcast completion, including the auto-advance
        // case that never reaches `handlePodcastPlaybackFinished` (that one
        // only fires when nothing was queued behind it). Retirement alone,
        // not queue removal: this runs mid-suspension inside the
        // controller's own completion handling, before it re-reads queue
        // state, and mutating the queue here would race that read.
        playback?.podcastCompletionHandler = { [weak self] episodeID in
            Task { [weak self] in
                guard let self else { return }
                _ = await self.completeAndRetire(episodeID)
                await self.reloadLibraryRows()
            }
        }
        // An episode that ends with nothing behind it stops the audio without
        // changing which item is loaded. The on-screen readout would catch up
        // on its next tick, but the system widget has no tick of its own, so
        // without this it would sit there claiming to be playing. For a
        // podcast episode this is also the only signal that the Producer's
        // own Up Next queue had nothing to advance into, which is where
        // continuing across the Larder picks up.
        playback?.playbackDidFinishHandler = { [weak self] in
            self?.handlePodcastPlaybackFinished()
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
        var selectedSyncFactory = syncTransportFactory
#if WILTED_CLOUDKIT_LIVE
        if !fixtureMode, selectedSyncFactory == nil, let configuredStore {
            let liveConfiguration = WiltedMacLiveSyncConfiguration(
                database: CKContainer(identifier: "iCloud.com.zerodelta.wilted").privateCloudDatabase,
                assetRootURL: mediaDirectory,
                store: configuredStore,
                assetResolver: assetResolver
            )
            selectedSyncFactory = makeWiltedMacLiveSyncTransportFactory(configuration: liveConfiguration)
        }
#endif
        syncLifecycle = configuredStore.map {
            WiltedMacSyncLifecycle(
                store: $0,
                transportFactory: fixtureMode ? nil : selectedSyncFactory,
                assetResolver: assetResolver
            )
        }
    }

    private func restorePodcastPlayback() async {
        guard let playback else { return }
        playbackOperationStatus = "Restoring Larder…"
        await playback.restorePodcastQueue()
        await refreshPodcastQueueState()
        if let itemID = playback.itemID,
           episodes.contains(where: { $0.id == itemID.rawValue }) {
            currentPodcastEpisodeID = itemID.rawValue
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
            refreshPlaybackReadout()
            await loadEpisodeTranscript(itemID: itemID)
        }
        playbackOperationStatus = nil
    }

#endif
#endif
}
