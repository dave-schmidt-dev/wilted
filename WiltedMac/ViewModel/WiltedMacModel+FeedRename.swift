import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// Only the presentation name is optimistic; publisher identity and episode lifecycle remain factual.
struct WiltedMacFeedRenameState {
    let displayName: String?
}

extension WiltedMacModel {
    func feedRenameDisplayName(_ feedID: String, stored: String?) -> String? {
        if let pending = pendingFeedRenames[feedID] { return pending.displayName }
        return stored
    }

    func applyingPendingFeedRename(_ row: WiltedMacSubscription) -> WiltedMacSubscription {
        guard let pending = pendingFeedRenames[row.id] else { return row }
        return renamedSubscription(row, displayName: pending.displayName)
    }

    private func renamedSubscription(_ row: WiltedMacSubscription, displayName: String?) -> WiltedMacSubscription {
        WiltedMacSubscription(
            id: row.id, title: displayName ?? row.publisherTitle ?? row.title, feedURL: row.feedURL,
            episodeCount: row.episodeCount, subscribedAt: row.subscribedAt, enabled: row.enabled,
            publisherTitle: row.publisherTitle, displayName: displayName)
    }

    /// Updates only existing presentation labels, preserving skipped/retired rows and all their state.
    private func showFeedName(_ feedID: String, displayName: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == feedID }) else { return }
        let row = renamedSubscription(subscriptions[index], displayName: displayName)
        subscriptions[index] = row
        for index in episodes.indices where episodes[index].feedID == feedID {
            episodes[index].feedTitle = row.title
        }
    }

    private func invalidateFeedRenameReads() {
        libraryReadEpoch &+= 1
        lastAppliedLibraryReadEpoch = libraryReadEpoch
    }

#if canImport(WiltedProducer)
    /// Projects the name before the writer's first suspension. The existing finite ledger owns saving.
    func renameSubscription(_ subscription: WiltedMacSubscription, to displayName: String) async throws {
        guard let store, !isClosingTemporaryState, pendingFeedWrites[subscription.id] == nil,
              let before = subscriptions.first(where: { $0.id == subscription.id }) else {
            throw WiltedMacRemovalUnavailable()
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : trimmed
        pendingFeedWrites[subscription.id] = .updating(enabled: before.enabled)
        pendingFeedRenames[subscription.id] = WiltedMacFeedRenameState(displayName: name)
        invalidateFeedRenameReads()
        showFeedName(subscription.id, displayName: name)
        defer {
            pendingFeedRenames[subscription.id] = nil
            pendingFeedWrites[subscription.id] = nil
            invalidateFeedRenameReads()
            if let queued = queuedFeedEnabled.removeValue(forKey: subscription.id),
               let latest = subscriptions.first(where: { $0.id == subscription.id }) {
                setSubscription(latest, enabled: queued)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trackSubscriptionWrite {
                do {
                    try await self.subscriptionWriteHookForTesting?()
                    guard !self.isClosingTemporaryState, !Task.isCancelled else { throw WiltedMacRemovalUnavailable() }
                    try await store.setSubscriptionDisplayName(
                        feedID: ItemID(rawValue: subscription.id), displayName: name)
                    // A rename never republishes a whole library snapshot over a newer Keep/Skip.
                    continuation.resume()
                } catch {
                    self.showFeedName(subscription.id, displayName: before.displayName)
                    self.podcastOperationMessage = "\(before.title) could not be renamed. Try again."
                    continuation.resume(throwing: error)
                }
            }
        }
    }
#endif
}
