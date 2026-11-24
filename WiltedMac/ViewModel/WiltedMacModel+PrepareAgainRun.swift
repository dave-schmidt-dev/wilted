import Foundation
import os
import WiltedDomain
import WiltedLibrary
import WiltedProducer

/// What a Larder row says about a prepare-again run on a cut episode.
///
/// The run leaves the row `Ready`: the old cut stays playable throughout, so
/// the row's preparation state cannot carry the run (a `.preparing` row moves
/// to the Downloaded group and hides Play). This is the run's own line.
struct WiltedMacPrepareAgainRow: Equatable {
    enum Phase: Equatable {
        /// Behind another preparation for the one slot.
        case waiting
        /// Fetching the original; the fraction is nil until the size is known.
        case downloading(fraction: Double?)
        /// The original is here and the engine is working on it.
        case preparing
        /// The run is over and left the cut as it was. Nothing to retry: the
        /// text says why, and the episode is offered again only if it still
        /// should be.
        case note(String)
    }

    var phase: Phase
    /// Taken from the policy the run was admitted with: when ad removal is off,
    /// the preparing line says the full episode is being restored.
    var restoringFullEpisode: Bool = false

    var isRunning: Bool {
        if case .note = phase { false } else { true }
    }

    var fraction: Double? {
        if case .downloading(let fraction) = phase { fraction } else { nil }
    }

    /// The sentence on the row.
    var label: String {
        switch phase {
        case .waiting: "Waiting for the preparation in flight"
        case .downloading(let fraction):
            fraction.map { "Downloading the original · \(Int(($0 * 100).rounded()))%" } ?? "Downloading the original"
        case .preparing:
            restoringFullEpisode ? "Restoring the full episode" : "Removing ads with the current engine"
        case .note(let text): text
        }
    }
}

extension WiltedMacModel {
    /// File > Prepare Again With Current Engine (n)…
    nonisolated static func prepareAgainCommandTitle(count: Int) -> String {
        "Prepare Again With Current Engine (\(count))\u{2026}"
    }

    nonisolated static func prepareAgainConfirmationTitle(count: Int) -> String {
        "Prepare \(count) episodes again?"
    }

    nonisolated static let prepareAgainConfirmationMessage =
        "Wilted downloads the original audio where needed and prepares each episode with the current engine. "
        + "Shows marked as already ad-free get their full episodes back. Your place in each is kept."

    // MARK: Row

    /// The row's state when an admitted run starts: a cut keeps its Ready row
    /// and gets the run's own line, anything else shows the usual `.preparing`.
    func showPreparationAdmitted(
        _ episodeID: String, queued: Bool, again: Bool, restoringFullEpisode: Bool = false
    ) {
        guard again else {
            updateEpisode(episodeID) {
                $0.preparationState = .preparing(stage: queued ? Self.preparationQueuedStage : Self.preparingStage)
            }
            return
        }
        prepareAgainRows[episodeID] = WiltedMacPrepareAgainRow(
            phase: queued ? .waiting : .downloading(fraction: nil),
            restoringFullEpisode: restoringFullEpisode
        )
    }

    /// A queued run reached the slot.
    func showPreparationStarted(
        _ episode: WiltedMacEpisode, again: Bool, restoringFullEpisode: Bool = false
    ) {
        if again {
            prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                phase: .downloading(fraction: nil), restoringFullEpisode: restoringFullEpisode
            )
        } else {
            updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparingStage) }
        }
        podcastOperationMessage = "Preparing \(episode.title)…"
    }

    /// Clears the live line when the run ends; a note stays for the listener.
    func finishPrepareAgainRow(_ episodeID: String) {
        if prepareAgainRows[episodeID]?.isRunning == true { prepareAgainRows[episodeID] = nil }
    }

    func showPrepareAgainDownload(_ episodeID: String, _ progress: PodcastDownloadProgress) {
        guard let existing = prepareAgainRows[episodeID] else { return }
        switch existing.phase {
        case .waiting, .downloading:
            if progress.stage == .completed {
                prepareAgainRows[episodeID] = WiltedMacPrepareAgainRow(
                    phase: .preparing, restoringFullEpisode: existing.restoringFullEpisode
                )
            } else {
                let fraction = progress.expectedByteCount.flatMap { $0 > 0 ? $0 : nil }
                    .map { min(1, Double(progress.bytesReceived) / Double($0)) }
                prepareAgainRows[episodeID] = WiltedMacPrepareAgainRow(
                    phase: .downloading(fraction: fraction),
                    restoringFullEpisode: existing.restoringFullEpisode
                )
            }
        default: break
        }
    }

    // MARK: Endings

    /// A stopped run. A cut was never taken out of Ready, so its row needs no
    /// state back; anything else returns to Not prepared.
    func markPreparationCancelled(_ episodeID: String, again: Bool) {
        if !again { updateEpisode(episodeID) { $0.preparationState = .notPrepared } }
        podcastOperationMessage = "Preparation cancelled."
    }

    /// A failed run. A failed cut is not a failed episode: the old cut is
    /// ready, and a Retry would run a plain prepare over it, so the row keeps
    /// Ready and says what happened.
    func markPreparationFailed(_ episode: WiltedMacEpisode, error: any Error, again: Bool) {
        guard again else {
            preparationFailureCauses[episode.id] = Self.preparationFailureCause(for: error)
            updateEpisode(episode.id) { $0.preparationState = .failed(Self.preparationFailedLabel) }
            podcastOperationMessage = "\(episode.title): \(Self.preparationFailedLabel)"
            return
        }
        let note: String
        if let cause = Self.prepareAgainFailureCause(for: error) {
            note = "Could not download the original (\(cause)), so nothing changed"
        } else if error is PodcastDownloadCoordinatorError {
            note = "Could not download the original, so nothing changed"
        } else {
            note = "Preparing again failed, so nothing changed"
        }
        prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(phase: .note(note))
        podcastOperationMessage = "\(episode.title): \(note)"
    }

    /// Returns a short, safe explanation for an original-download failure.
    /// Only fixed status text and URL error codes reach the row.
    nonisolated static func prepareAgainFailureCause(for error: Error) -> String? {
        if case PodcastDownloadCoordinatorError.invalidResponse(let status?) = error {
            return "HTTP \(status)"
        }
        if case PodcastDownloadCoordinatorError.invalidResponse(nil) = error {
            return "invalid response"
        }
        if let urlError = error as? URLError {
            return prepareAgainFailureCause(forURLErrorCode: urlError.code.rawValue)
        }
        return nil
    }

    private nonisolated static func prepareAgainFailureCause(forURLErrorCode code: Int) -> String {
        switch URLError.Code(rawValue: code) {
        case .timedOut: return "timed out"
        case .networkConnectionLost: return "network connection lost"
        case .notConnectedToInternet: return "offline"
        case .cannotFindHost: return "cannot find host"
        case .cannotConnectToHost: return "cannot connect to host"
        case .dnsLookupFailed: return "DNS lookup failed"
        case .internationalRoamingOff: return "roaming off"
        case .dataNotAllowed: return "data not allowed"
        case .callIsActive: return "call active"
        default: return "download failed"
        }
    }

    /// A run whose request could not be saved. A cut keeps its Ready row for
    /// the same reason `markPreparationFailed` does.
    func markPreparationNotStarted(_ episode: WiltedMacEpisode, again: Bool) {
        guard again else {
            updateEpisode(episode.id) {
                $0.preparationState = .failed("Preparation could not start. Retry from Larder.")
            }
            podcastOperationMessage = "Preparation could not start because its request was not saved. Retry from Larder."
            return
        }
        let note = "Preparing again could not start, so nothing changed"
        prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(phase: .note(note))
        podcastOperationMessage = "\(episode.title): \(note)"
    }

    // MARK: Run

    /// Fetches the original for a prepare-again run, retrying transient network
    /// errors and HTTP 5xx responses with a bounded, increasing delay.
    func stageOriginalRetryingTransientFailures(
        _ coordinator: PodcastDownloadCoordinator, episodeID: ItemID, enclosureURL: URL,
        onStatus: @escaping @Sendable (PodcastDownloadProgress) -> Void
    ) async throws -> StagedPodcastAudio {
        var retry = 0
        while true {
            do {
                return try await coordinator.stageOriginal(
                    episodeID: episodeID, enclosureURL: enclosureURL, onStatus: onStatus)
            } catch {
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                    || (error as? PodcastDownloadCoordinatorError) == .cancelled {
                    throw CancellationError()
                }
                let retryable = Self.isTransientPrepareAgainFailure(error)
                let cause = Self.prepareAgainFailureCause(for: error) ?? "download failed"
                guard retryable, retry < WiltedAutomationCoordinator.maximumRetries else {
                    Self.downloadLog.error(
                        "prepare-again download failed: episode=\(episodeID.rawValue, privacy: .public) cause=\(cause, privacy: .public) retries=\(retry, privacy: .public)"
                    )
                    throw error
                }
                retry += 1
                let delay = WiltedAutomationCoordinator.baseRetryDelay * pow(2, Double(retry - 1))
                Self.downloadLog.warning(
                    "prepare-again download failed: episode=\(episodeID.rawValue, privacy: .public) cause=\(cause, privacy: .public) retry=\(retry, privacy: .public) afterSeconds=\(delay, privacy: .public)"
                )
                try await prepareAgainRetrySleep(delay)
            }
        }
    }

    private nonisolated static func isTransientPrepareAgainFailure(_ error: Error) -> Bool {
        if case PodcastDownloadCoordinatorError.invalidResponse(let status?) = error {
            return (500..<600).contains(status)
        }
        if let urlError = error as? URLError {
            return MediaFetchErrorClassifier.isTransient(urlError)
        }
        return false
    }

    /// Runs one admitted preparation and returns the sentence that reports it.
    ///
    /// A cut episode is prepared from a staged copy of its original while the
    /// old cut stays ready; every other episode uses the plain pipeline over
    /// the original it still holds. A run that replaced nothing (the engine
    /// could not resolve the ads, or the listener's place could not be carried)
    /// is a normal ending with a note on the row.
    func runPreparation(
        pipeline: PodcastPreparationPipeline,
        itemID: ItemID,
        episode: WiltedMacEpisode,
        policy: PodcastPreparationPolicySnapshot,
        attempt: PreparationAttemptIdentity,
        again: PodcastPrepareAgainCandidate?
    ) async throws -> String {
        let onJournaled: @Sendable () async -> Void = { [weak self] in
            await MainActor.run { self?.librarySyncController?.requestPublish() }
        }
        guard let again else {
            return try await pipeline.prepare(
                episodeID: itemID, policy: policy, attempt: attempt, onJournaled: onJournaled
            ).summary
        }
        let restoring = !policy.removeAds
        do {
            guard let coordinator = podcastDownloadCoordinator else { throw CancellationError() }
            // A bulk run can wait for hours, and the listener can load the
            // episode meanwhile: its cut is not swapped under the playhead.
            if currentPodcastEpisodeID == episode.id {
                prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                    phase: .note("Playing now, so it was left as it is"),
                    restoringFullEpisode: restoring
                )
                throw CancellationError()
            }
            prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                phase: .downloading(fraction: nil), restoringFullEpisode: restoring
            )
            let throttle = WiltedMacDownloadProgressThrottle()
            let episodeID = episode.id
            let outcome = try await pipeline.prepareAgain(
                candidate: again,
                stage: {
                    try await self.stageOriginalRetryingTransientFailures(
                        coordinator, episodeID: itemID, enclosureURL: again.enclosureURL
                    ) { report in
                        throttle.submit(report) { progress in
                            Task { @MainActor in self.showPrepareAgainDownload(episodeID, progress) }
                        }
                    }
                },
                policy: policy, attempt: attempt,
                // Loaded in the player since the run began: the cut is not
                // swapped under the playhead.
                mayReplace: { await MainActor.run { self.currentPodcastEpisodeID != episodeID } },
                onJournaled: onJournaled
            )
            switch outcome {
            case .prepared(let result):
                return result.summary
            case .keptExisting(let summary):
                prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                    phase: .note(summary), restoringFullEpisode: restoring
                )
                return summary
            case .refused(let refusal):
                prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                    phase: .note(refusal.message), restoringFullEpisode: restoring
                )
                return refusal.message
            }
        } catch {
            if error is CancellationError, currentPodcastEpisodeID == episode.id {
                prepareAgainRows[episode.id] = WiltedMacPrepareAgainRow(
                    phase: .note("Playing now, so it was left as it is"),
                    restoringFullEpisode: restoring
                )
            }
            // A failed run counts as tried; the offer should reflect it now,
            // not at the next library load.
            if let store { await refreshEpisodesToPrepareAgain(from: store, readEpoch: libraryReadEpoch) }
            // A stopped staging download is a stop, not a failure.
            throw (error as? PodcastPreparationError) == .cancelled ? CancellationError() : error
        }
    }
}
