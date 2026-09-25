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
    /// Distinguishes "someone else already holds this download's claim" from
    /// genuine cancellation, so `withRetries`/`drain` skip just this episode
    /// instead of reading it as the whole automation pass stopping.
    private struct PodcastClaimAlreadyHeld: Error, WiltedAutomationNonRetryable {}

    /// Starts one episode's download.
    ///
    /// `alreadyClaimed` is automation saying it holds the store claim already.
    /// Every other caller takes the claim here, because the in-memory task table
    /// below only knows about this process: a claim an earlier launch made, or
    /// one automation took a moment ago, is invisible to it, and the download
    /// coordinator writes its queued record unconditionally. Without the claim
    /// the same episode transfers twice.
    func downloadEpisode(_ episode: WiltedMacEpisode, alreadyClaimed: Bool = false, ignoringExisting: Bool = false) {
#if canImport(WiltedProducer)
        guard podcastDownloadTasks[episode.id] == nil,
              let coordinator = podcastDownloadCoordinator,
              let itemID = try? ItemID(rawValue: episode.id) else { return }
        // The download is the request: its place in the preparation line is
        // taken now, so a later download that finishes first still queues
        // behind it.
        registerPreparationRequest(for: episode.id)
        // A distinct ticket from the preparation one above -- downloads are
        // not ordered against each other (`registerPreparationRequest`'s
        // number is for the preparation gate only), so this one's sequence
        // is whatever the store allocates next.
        Task { [weak self] in
            await self?.recordWorkTicketTransition(
                kind: .podcastDownload, subjectID: episode.id, state: .pending
            )
        }
        updateEpisode(episode.id) { $0.downloadState = .queued }
        podcastOperationMessage = "Queued \(episode.title) for download."
        podcastDownloadTasks[episode.id] = Task { [weak self] in
            guard let self else { throw CancellationError() }
            // One place to clear the task-table entry, run on every exit
            // (return or throw) rather than duplicated in each branch below.
            defer { self.podcastDownloadTasks[episode.id] = nil }
            // Fixture rows are published immediately for a responsive launch,
            // while their store records are installed asynchronously. Wait for
            // that install before exercising the real coordinator so a fast UI
            // retry cannot race the episode lookup and fail a second time.
            if self.fixtureMode {
                await self.fixturePodcastInstallTask?.value
            }
            if !alreadyClaimed {
                let won = await self.claimDownload(itemID)
                guard won else {
                    self.podcastOperationMessage = "\(episode.title) is already downloading."
                    self.updateEpisode(episode.id) { $0.downloadState = .notDownloaded }
                    // Someone else holds this episode; that is not a transfer
                    // failure, so `waitForPodcastOperations`'s `try?` swallow
                    // is the right place for this to disappear. It also must
                    // not read as `CancellationError`, which `drain` treats as
                    // the whole automation pass stopping rather than one claim
                    // being skipped.
                    throw PodcastClaimAlreadyHeld()
                }
            }
            await self.recordWorkTicketTransition(
                kind: .podcastDownload, subjectID: episode.id, state: .running
            )
            do {
                guard let store = self.store else { throw CancellationError() }
                let result = try await coordinator.download(episodeID: itemID,
                                                             ignoringExisting: ignoringExisting) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.updateActiveEpisodeDownload(
                            episode.id,
                            received: progress.bytesReceived,
                            expected: progress.expectedByteCount
                        ) == true else { return }
                        self?.podcastOperationMessage = "Downloading \(episode.title)…"
                    }
                }
                let recoveryCheckpointSaved: Bool
                do {
                    // The marker is durable, so an unresolved fingerprint must
                    // not write one: the sentinel would read as a different
                    // pipeline once a real fingerprint resolves. Leaving the
                    // forced marker in place is the same conservative outcome
                    // as a failed write below.
                    guard let fingerprint = self.pipelineFingerprint
                        ?? PodcastPreparationPipeline.semanticFingerprintResolution else {
                        throw WiltedMacUnresolvedFingerprint()
                    }
                    try await store.markForcedRedownloadCompleted(
                        for: itemID,
                        currentFingerprint: fingerprint
                    )
                    recoveryCheckpointSaved = true
                } catch {
                    // The verified download is still valid. Keeping the forced
                    // marker is conservative and lets a later launch retry;
                    // misreporting this as a failed transfer would be false.
                    recoveryCheckpointSaved = false
                }
                self.podcastOperationMessage = recoveryCheckpointSaved
                    ? "\(episode.title) is available offline."
                    : "\(episode.title) downloaded, but its preparation recovery checkpoint could not be saved."
                // Asked for before the library is reloaded, not after. The
                // reload reads the whole library and three downloads landing
                // together each run one, so preparation used to be requested
                // seconds after the transfer it follows -- and until it is
                // requested the row has no state to keep and nothing names it
                // as pending. It reports what it will do straight away, so the
                // reload below has something to preserve.
                if self.automationSettings.prepareEverythingDownloaded,
                   self.podcastQueueIDs.contains(episode.id) {
                    // The override prepares immediately, exactly as the group's
                    // Prepare all does, and only for an episode waiting on the
                    // Menu; with it off the processing policy's own plan
                    // (including off-peak) still governs the arrival.
                    self.prepareEpisode(episode)
                } else {
                    self.admitAutomaticPreparation(for: episode, at: Date())
                }
                // The file has landed and its preparation is under way, so a
                // reload that fails from here leaves stale rows -- it does not
                // mean the download failed, and the catch below would say so.
                // The next reload picks the rows up.
                do {
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                    self.dismissedEpisodes = try await self.loadDismissedEpisodes(from: store)
                } catch {}
                await self.recordWorkTicketTransition(
                    kind: .podcastDownload, subjectID: episode.id, state: .succeeded
                )
                return result
            } catch PodcastDownloadCoordinatorError.cancelled {
                self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                self.podcastOperationMessage = "Download cancelled."
                await self.recordWorkTicketTransition(
                    kind: .podcastDownload, subjectID: episode.id, state: .cancelled
                )
                throw PodcastDownloadCoordinatorError.cancelled
            } catch {
                self.updateEpisode(episode.id) { $0.downloadState = .failed }
                self.podcastOperationMessage = "Download failed. Retry when you are online."
                // This is the across-attempt seam: `withRetries` (unchanged,
                // in `WiltedAutomationCoordinator`) retries a `.retryable`
                // failure in-process up to its own bound before this throw
                // ever escapes back out to it; a `.terminal` one is wrapped
                // non-retryable one call up, in `startClaimedDownload`, so
                // `withRetries` never sees it twice. Either way, by the time
                // this catch runs the ticket is the durable record of that
                // attempt's outcome, independent of whether automation or a
                // deliberate click made it.
                let failureKind = (error as? PodcastDownloadCoordinatorError)?.failureKind ?? .retryable
                await self.recordWorkTicketTransition(
                    kind: .podcastDownload, subjectID: episode.id, state: .failed,
                    failureKind: failureKind.rawValue, lastFailureMessage: String(describing: error)
                )
                throw error
            }
        }
#endif
    }

    /// Takes the store claim for a deliberate download, so a transfer already in
    /// flight -- from automation, or from a launch that ended mid-download --
    /// is not started a second time. A settled record does not block: retrying
    /// a failure from the row is exactly what that path is for.
#if canImport(WiltedProducer)
    private func claimDownload(_ episodeID: ItemID) async -> Bool {
        guard let store else { return false }
        return (try? await store.claimPodcastDownload(episodeID: episodeID, scope: .notInFlight)) ?? false
    }
#endif

    /// One automatic job held outside the preparation gate until its original
    /// off-peak window opens.
    struct DeferredAutomaticPreparation: Codable, Equatable {
        let episodeID: String
        let processingPolicy: WiltedAutomationProcessingPolicy
        let policySnapshot: PodcastPreparationPolicySnapshot
    }

    private struct DeferredAutomaticPreparationEnvelope: Codable {
        static let currentVersion = 1
        let version: Int
        let jobs: [DeferredAutomaticPreparation]
    }

    static func loadDeferredAutomaticPreparations(
        from preferences: UserDefaults
    ) -> [DeferredAutomaticPreparation] {
        guard let data = preferences.data(forKey: deferredAutomaticPreparationsPreferenceKey),
              let envelope = try? JSONDecoder().decode(DeferredAutomaticPreparationEnvelope.self, from: data),
              envelope.version == DeferredAutomaticPreparationEnvelope.currentVersion else { return [] }
        var seen: Set<String> = []
        return envelope.jobs.filter { job in
            guard !job.episodeID.isEmpty,
                  case .offPeak = job.processingPolicy,
                  seen.insert(job.episodeID).inserted else { return false }
            return true
        }
    }

    static func persistDeferredAutomaticPreparations(
        _ jobs: [DeferredAutomaticPreparation], to preferences: UserDefaults
    ) {
        guard !jobs.isEmpty else {
            preferences.removeObject(forKey: Self.deferredAutomaticPreparationsPreferenceKey)
            return
        }
        let envelope = DeferredAutomaticPreparationEnvelope(
            version: DeferredAutomaticPreparationEnvelope.currentVersion,
            jobs: jobs
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        preferences.set(data, forKey: Self.deferredAutomaticPreparationsPreferenceKey)
    }

    private func persistDeferredAutomaticPreparations() {
        Self.persistDeferredAutomaticPreparations(deferredAutomaticPreparations, to: preferences)
    }

    /// Maps the settings visible when a job is admitted into the worker's
    /// immutable request shape.
    static func preparationPolicySnapshot(
        from settings: WiltedAutomationSettings
    ) -> PodcastPreparationPolicySnapshot {
        let transcriptPolicy: PodcastTranscriptPolicy
        switch settings.transcriptPolicy {
        case .bestAvailable: transcriptPolicy = .bestAvailable
        case .alwaysTranscribe: transcriptPolicy = .alwaysTranscribe
        case .noLocalSTT: transcriptPolicy = .noLocalSTT
        }
        return PodcastPreparationPolicySnapshot(
            transcriptPolicy: transcriptPolicy,
            removeAds: settings.removeAds
        )
    }

    /// Starts, defers, or skips preparation for an automatically downloaded
    /// episode. Manual preparation deliberately does not pass through here.
    func admitAutomaticPreparation(for episode: WiltedMacEpisode, at date: Date) {
        let settings = automationSettings
        let snapshot = Self.preparationPolicySnapshot(from: settings)
        switch WiltedAutomationCoordinator.preparationPlan(
            processingPolicy: settings.processingPolicy, at: date
        ) {
        case .prepareNow:
            prepareEpisode(episode, policySnapshot: snapshot)
        case .skip:
            break
        case .deferUntilOffPeak:
            guard !deferredAutomaticPreparations.contains(where: { $0.episodeID == episode.id }) else { return }
            deferredAutomaticPreparations.append(DeferredAutomaticPreparation(
                episodeID: episode.id,
                processingPolicy: settings.processingPolicy, policySnapshot: snapshot
            ))
            persistDeferredAutomaticPreparations()
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episode.id, title: episode.title, source: episode.feedTitle
            ))
            updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparationQueuedStage) }
            podcastOperationMessage = "\(episode.title) is queued for off-peak preparation."
        }
    }

    /// Whether this episode is waiting for an off-peak window rather than
    /// being prepared right now.
    ///
    /// The two are indistinguishable from `preparationState` alone: a deferred
    /// job is stored as `.preparing(stage: "Queued")` so the row shows it is
    /// spoken for, which also makes `isRunning` true. A reader looking at a
    /// deferred row sees "Preparing…" and a Stop button for work that has not
    /// started and will not start for hours.
    func isDeferredForOffPeak(_ episodeID: String) -> Bool {
        deferredAutomaticPreparations.contains { $0.episodeID == episodeID }
    }

    /// Prepares a deferred episode now, overriding its off-peak window.
    ///
    /// The window is a default, not a rule: a listener who wants this episode
    /// on the walk they are about to take should not have to change a Settings
    /// policy and wait for the next re-evaluation. The stored policy snapshot
    /// is reused rather than re-read, so overriding one episode does not
    /// quietly re-policy it under settings edited since it was admitted.
    ///
    /// Returns false when the episode is not deferred or the gate refuses it,
    /// and in the refusal case the deferral is left in place so the off-peak
    /// pass still owns it.
    @discardableResult
    func prepareDeferredEpisodeNow(_ episode: WiltedMacEpisode) -> Bool {
        guard let deferred = deferredAutomaticPreparations.first(where: { $0.episodeID == episode.id })
        else { return false }
        preparationQueue.leave(episode.id)
        guard prepareEpisode(episode, policySnapshot: deferred.policySnapshot) else {
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episode.id, title: episode.title, source: episode.feedTitle
            ))
            return false
        }
        removeDeferredAutomaticPreparation(episode.id, leaveQueue: false)
        return true
    }

    /// Re-evaluates only already-admitted off-peak jobs. Later Settings edits
    /// do not affect the stored policy snapshot or its window.
    func startEligibleAutomaticPreparations(at date: Date = Date()) {
        let eligible = deferredAutomaticPreparations.filter { deferred in
            WiltedAutomationCoordinator.preparationPlan(
                processingPolicy: deferred.processingPolicy, at: date
            ) == .prepareNow
        }
        for deferred in eligible {
            guard let episode = episodes.first(where: { $0.id == deferred.episodeID }) else {
                removeDeferredAutomaticPreparation(deferred.episodeID)
                continue
            }
            preparationQueue.leave(deferred.episodeID)
            if prepareEpisode(episode, policySnapshot: deferred.policySnapshot) {
                removeDeferredAutomaticPreparation(deferred.episodeID, leaveQueue: false)
            } else {
                preparationQueue.enter(WiltedMacWaitingPreparation(
                    id: episode.id, title: episode.title, source: episode.feedTitle
                ))
            }
        }
    }

    func removeDeferredAutomaticPreparation(_ episodeID: String, leaveQueue: Bool = true) {
        let oldCount = deferredAutomaticPreparations.count
        deferredAutomaticPreparations.removeAll { $0.episodeID == episodeID }
        guard deferredAutomaticPreparations.count != oldCount else { return }
        if leaveQueue { preparationQueue.leave(episodeID) }
        persistDeferredAutomaticPreparations()
    }

    /// Rebuilds the visible queue only after the library rows exist, then
    /// starts work whose original window is already open. Missing, no-longer-
    /// downloaded, and already-prepared rows cannot be resumed and are pruned.
    func restoreDeferredAutomaticPreparations(at date: Date = Date()) {
        let resumable = Set(episodes.compactMap { episode -> String? in
            guard episode.downloadState == .completed, !episode.preparationState.isPrepared else { return nil }
            return episode.id
        })
        deferredAutomaticPreparations.removeAll { !resumable.contains($0.episodeID) }
        persistDeferredAutomaticPreparations()
        for deferred in deferredAutomaticPreparations {
            guard let episode = episodes.first(where: { $0.id == deferred.episodeID }) else { continue }
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episode.id, title: episode.title, source: episode.feedTitle
            ))
            updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparationQueuedStage) }
        }
        startEligibleAutomaticPreparations(at: date)
    }

    /// Issues this episode's preparation request sequence, or returns the one
    /// it already holds. Called when the reader asks for the episode -- the
    /// Download button or an automation download -- so the place in line is
    /// the click's, not the download completion's.
    @discardableResult
    func registerPreparationRequest(for episodeID: String) -> Int {
        if let existing = preparationRequestSequences[episodeID] { return existing }
        let sequence = nextPreparationRequestSequence()
        preparationRequestSequences[episodeID] = sequence
        Task { [weak self] in
            await self?.recordWorkTicketTransition(
                kind: .podcastPreparation, subjectID: episodeID,
                requestSequence: sequence, state: .pending, admitting: true
            )
        }
        return sequence
    }

    /// Advances and persists the counter without recording a pending request.
    /// A run that is already starting has no place to keep.
    func nextPreparationRequestSequence() -> Int {
        preparationRequestSequence += 1
        preferences.set(preparationRequestSequence, forKey: Self.preparationRequestSequencePreferenceKey)
        return preparationRequestSequence
    }

    /// Takes this episode's request sequence for the run that is starting.
    /// Falls back to a fresh number when the request did not come through a
    /// download (a manual Prepare on an already-downloaded episode).
    @discardableResult
    func consumePreparationRequest(
        for episodeID: String,
        kind: WorkTicketKind = .podcastPreparation,
        policySnapshot: Data? = nil,
        processingPolicy: Data? = nil
    ) -> Int {
        let sequence: Int
        if let existing = preparationRequestSequences.removeValue(forKey: episodeID) {
            sequence = existing
        } else {
            sequence = nextPreparationRequestSequence()
        }
        // One write for this transition, carrying whatever policy is already
        // known at admission time in the same call: two separate fire-and-
        // forget writes here (one for the state, one for the policy) would
        // race each other's read-modify-write against the same ticket row.
        Task { [weak self] in
            await self?.recordWorkTicketTransition(
                kind: kind, subjectID: episodeID, requestSequence: sequence, state: .running,
                policySnapshot: policySnapshot, processingPolicy: processingPolicy, admitting: true
            )
        }
        return sequence
    }

    /// Gives up a request's place, for a row that can no longer run: a retired,
    /// hidden, or removed episode. The sequence itself is not reused.
    func withdrawPreparationRequest(for episodeID: String) {
        preparationRequestSequences.removeValue(forKey: episodeID)
        Task { [weak self] in
            await self?.recordWorkTicketTransition(
                kind: .podcastPreparation, subjectID: episodeID, state: .cancelled
            )
        }
    }

}
