import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    enum FeedDecision { case keep, skip, restore }

    /// Captures the visible order before the task starts. The task is entered
    /// in the same finite-writer ledger that model close already drains.
    func decideFeedEpisodes(_ decision: FeedDecision, episodes candidates: [WiltedMacEpisode]) {
        let captured = uniqueFeedDecisionEpisodes(candidates)
        let ids = captured.map(\.id)
        guard !ids.isEmpty, pendingFeedDecisionIDs.isDisjoint(with: ids), !isClosingTemporaryState else { return }
        if decision == .skip {
            for id in ids { withdrawPreparationRequest(for: id) }
        }
        pendingFeedDecisionIDs.formUnion(ids)
        failedFeedDecisionIDs.subtract(ids)
        let token = UUID()
        let predecessor = feedDecisionWriteTailToken.flatMap { subscriptionWriteTasks[$0] }
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.subscriptionWriteTasks[token] = nil
                    if self.feedDecisionWriteTailToken == token { self.feedDecisionWriteTailToken = nil }
                }
            }
            guard let self else { return }
            // Captured before registration, so disjoint Feed decisions commit
            // in admission order and an older post-commit hook cannot publish
            // its queue snapshot after a newer durable writer.
            if let predecessor { await predecessor.value }
            guard !self.isClosingTemporaryState, !Task.isCancelled else {
                self.settleFeedDecision(captured.map(\.id), committed: [])
                return
            }
            await self.commitFeedDecision(decision, captured: captured)
        }
        // This synchronous insertion precedes the task body's first await.
        subscriptionWriteTasks[token] = task
        feedDecisionWriteTailToken = token
    }

    private func uniqueFeedDecisionEpisodes(_ candidates: [WiltedMacEpisode]) -> [WiltedMacEpisode] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private func commitFeedDecision(_ decision: FeedDecision, captured: [WiltedMacEpisode]) async {
        guard let store else { settleFeedDecision(captured.map(\.id), committed: []); return }
        let ids = captured.compactMap { try? ItemID(rawValue: $0.id) }
        guard ids.count == captured.count else { settleFeedDecision(captured.map(\.id), committed: []); return }
        do {
            await fixturePodcastInstallTask?.value
            guard !isClosingTemporaryState, !Task.isCancelled else {
                settleFeedDecision(captured.map(\.id), committed: [])
                return
            }
            try await feedDecisionBeforeCommitForTesting?()
            guard !isClosingTemporaryState, !Task.isCancelled else {
                settleFeedDecision(captured.map(\.id), committed: [])
                return
            }
            switch decision {
            case .keep:
                let outcome = try await commitManualKeep(captured, store: store)
                let (changed, accepted) = (outcome.changed, outcome.accepted)
                if !accepted.isEmpty {
                    advanceLibraryReadProvenance()
                    podcastQueueRefreshGeneration &+= 1
                }
                await feedDecisionAfterDurableCommitForTesting?()
                guard !isClosingTemporaryState, !Task.isCancelled else { return }
                podcastQueueIDs = outcome.queueIDs
                settleFeedDecision(captured.map(\.id), committed: accepted)
                for episode in outcome.downloads { downloadEpisode(episode) }
                podcastOperationMessage = decisionMessage("Kept", changed: changed.count, accepted: accepted.count, unresolved: outcome.unresolved.count)
            case .skip:
                let retiredAt = Timestamp(Date())
                let result = try await store.retireEpisodes(ids, at: retiredAt)
                let changed = Set(result.committed.map(\.rawValue))
                let accepted = changed.union(result.alreadyAtTarget.map(\.rawValue))
                try await recordManualDecisions(.skip, for: accepted, at: retiredAt, store: store)
                if !accepted.isEmpty { advanceLibraryReadProvenance() }
                await feedDecisionAfterDurableCommitForTesting?()
                guard !isClosingTemporaryState, !Task.isCancelled else { return }
                var retirementTimes = result.retiredAtByID.mapValues(\.date)
                for id in result.committed { retirementTimes[id] = retiredAt.date }
                applyRetirement(to: accepted, at: retirementTimes)
                settleFeedDecision(captured.map(\.id), committed: accepted)
                podcastOperationMessage = decisionMessage("Skipped", changed: changed.count, accepted: accepted.count, unresolved: result.unresolved.count)
                // A retirement frees a kept slot: let the feed's oldest waiting episode in.
                if !changed.isEmpty {
                    await releaseWaitingEpisodes(feedIDs: Set(captured.filter { changed.contains($0.id) }.compactMap(\.feedID)))
                }
            case .restore:
                let result = try await store.restoreEpisodes(ids)
                let changed = Set(result.committed.map(\.rawValue))
                let accepted = changed.union(result.alreadyAtTarget.map(\.rawValue))
                try await recordManualDecisions(.keep, for: accepted, at: Timestamp(Date()), store: store)
                if !accepted.isEmpty { advanceLibraryReadProvenance() }
                await feedDecisionAfterDurableCommitForTesting?()
                guard !isClosingTemporaryState, !Task.isCancelled else { return }
                applyRestoration(to: accepted)
                settleFeedDecision(captured.map(\.id), committed: accepted)
                podcastOperationMessage = decisionMessage("Restored", changed: changed.count, accepted: accepted.count, unresolved: result.unresolved.count)
            }
        } catch {
            settleFeedDecision(captured.map(\.id), committed: [])
            podcastOperationMessage = "Feed decision could not be saved."
        }
    }

    private func settleFeedDecision(_ ids: [String], committed: Set<String>) {
        pendingFeedDecisionIDs.subtract(ids)
        failedFeedDecisionIDs.subtract(committed)
        failedFeedDecisionIDs.formUnion(ids.filter { !committed.contains($0) })
    }

    private func advanceLibraryReadProvenance() {
        libraryReadEpoch &+= 1
        lastAppliedLibraryReadEpoch = libraryReadEpoch
    }

    private func decisionMessage(_ verb: String, changed: Int, accepted: Int, unresolved: Int) -> String {
        guard unresolved > 0 else {
            return changed == 0 ? "Those episodes were already \(verb.lowercased())." : "\(verb) \(changed) episode\(changed == 1 ? "" : "s")."
        }
        return "\(verb) \(accepted) of \(accepted + unresolved); \(unresolved) remain selected to retry."
    }

    private func applyRetirement(to ids: Set<String>, at retiredAtByID: [ItemID: Date]) {
        episodes = episodes.map { episode in
            guard ids.contains(episode.id), let id = try? ItemID(rawValue: episode.id) else { return episode }
            var value = episode
            value.retiredAt = retiredAtByID[id] ?? value.retiredAt
            value.removalKind = .retired
            return value
        }
    }

    private func applyRestoration(to ids: Set<String>) {
        episodes = episodes.map { episode in
            guard ids.contains(episode.id), episode.removalKind == .retired else { return episode }
            var value = episode; value.retiredAt = nil; value.removalKind = nil; return value
        }
    }
#endif
}
