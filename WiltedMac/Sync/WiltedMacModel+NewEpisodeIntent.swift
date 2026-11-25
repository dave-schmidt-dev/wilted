import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

extension WiltedMacModel {
    /// The phone's Keep or Skip is admitted only against the same live Feeds projection the
    /// Mac shows. The store repeats that check against its current rows in the receipt transaction.
    func commitNewEpisodeIntent(_ intent: LibraryIntent, decidedAt: Date) async -> IntentOutcome? {
        guard case let .decideNewEpisode(entryID, choice) = intent.action,
              let store else { return nil }

        await awaitingDecisionWriters {}
        let candidate = feedsEpisodeCandidates.first { $0.id == entryID.rawValue }
        let memberIDs = logicalMemberIDs(entryID.rawValue)
        pendingFeedDecisionIDs.formUnion(memberIDs)
        defer { pendingFeedDecisionIDs.subtract(memberIDs) }

        var downloadAfterKeep = false
        do {
            if choice == .keep, let candidate {
                var policy = FeedAutomationPolicy()
                if let rawFeedID = candidate.feedID, let feedID = try? ItemID(rawValue: rawFeedID) {
                    policy = try await store.feedAutomationPolicy(for: feedID)
                }
                let held = try? await store.podcastEpisodeIdentityReviewHeldIDs()
                downloadAfterKeep = Self.larderGroup(for: candidate) == .available
                    && !(held?.contains(entryID) ?? true)
                    && EpisodeAdmissionService.shouldDownloadAfterManualKeep(
                        feedPolicy: policy, globalDownloadEverything: automationSettings.downloadEverythingOnLarder
                    )
            }

            let result = try await store.commitNewEpisodeIntent(
                intent, macCurrentlyProjectsNew: candidate != nil,
                decidedAt: decidedAt, downloadAfterKeep: downloadAfterKeep
            )
            if !result.wasReplay, result.outcome.isApplied {
                advanceLibraryReadProvenance()
                podcastQueueRefreshGeneration &+= 1
                if choice == .skip {
                    for id in result.changedEpisodeIDs { withdrawPreparationRequest(for: id.rawValue) }
                }
            }
            // Refresh on a conflict too: a normal Mac Keep, Skip, or Undo may have been the
            // reason the stale phone row was no longer New.
            await refreshPodcastQueueState()
            await reloadLibraryRows()

            guard !result.wasReplay, result.outcome.isApplied else { return result.outcome }
            if choice == .keep, result.shouldStartDownload, let candidate {
                downloadEpisode(candidate, automatic: true)
            } else if choice == .skip, !result.changedEpisodeIDs.isEmpty {
                await releaseWaitingEpisodes(feedIDs: Set(result.feedIDs.map(\.rawValue)))
            }
            return result.outcome
        } catch {
            // A save can report an uncertain result. Read the durable receipt before reporting
            // failure; if it landed, this replay returns the exact committed outcome.
            do {
                let recovered = try await store.commitNewEpisodeIntent(
                    intent, macCurrentlyProjectsNew: candidate != nil,
                    decidedAt: decidedAt, downloadAfterKeep: downloadAfterKeep
                )
                await refreshPodcastQueueState()
                await reloadLibraryRows()
                return recovered.outcome
            } catch {
                return try? .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: decidedAt)
            }
        }
    }
}
