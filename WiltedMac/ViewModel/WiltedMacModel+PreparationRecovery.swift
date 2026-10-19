import Foundation
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    private static let preparationRecoveryLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "PreparationRecovery")

    /// Resumes existing durable demand after the library and raw Keep queue load.
    /// A pending download reservation is distinct from an admitted preparation.
    func restorePendingPodcastPreparations(
        in recoveringStore: LocalLibraryStore, at date: Date = Date(), excluding excludedIDs: Set<String> = []
    ) async {
        guard !isClosingTemporaryState, store === recoveringStore else { return }
        let attempt = startupAttemptCount
        var recoveryFailed = false
        do {
            let tickets = try await recoveringStore.workTickets().filter {
                $0.kind == .podcastPreparation && ($0.state == .pending || $0.state == .deferred)
            }.sorted {
                if $0.requestSequence != $1.requestSequence { return $0.requestSequence < $1.requestSequence }
                if $0.requestedAt != $1.requestedAt { return $0.requestedAt.date < $1.requestedAt.date }
                return $0.subjectID < $1.subjectID
            }
            let kept = Set(try await recoveringStore.podcastQueueState().episodeIDs.map(\.rawValue))
            for ticket in tickets {
                guard !isClosingTemporaryState, store === recoveringStore, startupAttemptCount == attempt else { return }
                guard kept.contains(ticket.subjectID), podcastQueueIDs.contains(ticket.subjectID),
                      !excludedIDs.contains(ticket.subjectID), podcastPreparationTasks[ticket.subjectID] == nil,
                      let episode = episodes.first(where: { $0.id == ticket.subjectID }),
                      !episode.isAudiobook, episode.removalKind == nil, episode.retiredAt == nil,
                      !hiddenEpisodeIDs.contains(episode.id), episode.downloadState == .completed,
                      !episode.preparationState.isPrepared else { continue }
                // Malformed persisted policy must never become today's settings.
                let snapshot: PodcastPreparationPolicySnapshot?
                let processing: WiltedAutomationProcessingPolicy?
                do {
                    snapshot = try ticket.policySnapshot.map {
                        try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: $0)
                    }
                    processing = try ticket.processingPolicy.map {
                        try JSONDecoder().decode(WiltedAutomationProcessingPolicy.self, from: $0)
                    }
                } catch {
                    recoveryFailed = true
                    Self.preparationRecoveryLog.warning("Invalid saved preparation policy: \(self.episodeLogContext(ticket.subjectID, requestSequence: ticket.requestSequence, attempt: ticket.attemptCount), privacy: .public) error=\(String(describing: error), privacy: .public)")
                    continue
                }
                if processing != nil, snapshot == nil {
                    recoveryFailed = true
                    Self.preparationRecoveryLog.warning("Missing saved preparation snapshot: \(self.episodeLogContext(ticket.subjectID, requestSequence: ticket.requestSequence, attempt: ticket.attemptCount), privacy: .public)")
                    continue
                }
                let waitingForDeadline = ticket.nextEligibleAt.map { $0.date > date } ?? false
                if let snapshot {
                    // A saved admission without a processing window was already
                    // runnable, including explicit Prepare under current Manual.
                    let admittedProcessing = processing ?? .immediate
                    let originalPlan = WiltedAutomationCoordinator.preparationPlan(
                        processingPolicy: admittedProcessing, at: date)
                    guard originalPlan != .skip else { continue }
                    let plan = waitingForDeadline ? .deferUntilOffPeak : originalPlan
                    switch plan {
                    case .skip: continue
                    case .prepareNow:
                        adoptAdmittedPreparation(sequence: ticket.requestSequence, for: episode.id)
                        removeDeferredAutomaticPreparation(episode.id)
                        prepareEpisode(episode, policySnapshot: snapshot)
                    case .deferUntilOffPeak:
                        // The existing ticker owns both admission deadlines and
                        // original off-peak windows, using the same saved policy.
                        adoptAdmittedPreparation(sequence: ticket.requestSequence, for: episode.id)
                        deferredAutomaticPreparations.removeAll { $0.episodeID == episode.id }
                        deferredAutomaticPreparations.append(DeferredAutomaticPreparation(
                            episodeID: episode.id, processingPolicy: admittedProcessing, policySnapshot: snapshot,
                            notBefore: ticket.nextEligibleAt?.date))
                        preparationQueue.enter(WiltedMacWaitingPreparation(id: episode.id, title: episode.title, source: episode.feedTitle))
                        updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparationQueuedStage) }
                    }
                } else {
                    // Unadmitted reservations cannot acquire today's policy
                    // before their durable eligibility deadline.
                    guard !waitingForDeadline else { continue }
                    // No worker policy was admitted yet. Preserve the ordinary
                    // download-arrival authority, including feed Off and Manual.
                    guard !(await automaticPreparationSuppressed(for: episode)) else { continue }
                    guard !isClosingTemporaryState, store === recoveringStore, startupAttemptCount == attempt,
                          podcastQueueIDs.contains(episode.id), podcastPreparationTasks[episode.id] == nil,
                          !hiddenEpisodeIDs.contains(episode.id),
                          episodes.contains(where: { $0.id == episode.id && $0.removalKind == nil
                              && $0.retiredAt == nil && !$0.isAudiobook && $0.downloadState == .completed
                              && !$0.preparationState.isPrepared }) else { continue }
                    guard automationSettings.prepareEverythingDownloaded
                        || WiltedAutomationCoordinator.preparationPlan(
                            processingPolicy: automationSettings.processingPolicy, at: date) != .skip else { continue }
                    adoptAdmittedPreparation(sequence: ticket.requestSequence, for: episode.id)
                    if automationSettings.prepareEverythingDownloaded { prepareEpisode(episode) }
                    else { admitAutomaticPreparation(for: episode, at: date) }
                }
            }
        } catch {
            recoveryFailed = true
            Self.preparationRecoveryLog.warning("Pending preparation recovery stopped: \(String(describing: error), privacy: .public)")
        }
        if recoveryFailed, podcastOperationMessage == nil, !isClosingTemporaryState,
           store === recoveringStore, startupAttemptCount == attempt {
            podcastOperationMessage = "Some saved preparations could not be restored. Prepare them again from Larder."
        }
    }
}
#endif
