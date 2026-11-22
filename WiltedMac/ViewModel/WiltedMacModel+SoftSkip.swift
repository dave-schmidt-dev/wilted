import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// A Skip from Feeds that can be taken back. It retires the episodes at once and keeps their audio
/// until the Undo window closes, so Undo gives back exactly what was there: the same decision, the
/// same audio, the same playback position.
extension WiltedMacModel {
    private static let pendingSoftSkipsKey = "wilted.pendingSoftSkips"

    /// Skips whose audio has not been reclaimed yet. Kept in the preferences so a quit inside the
    /// window cannot leave the audio behind for good: the next launch closes them.
    private var pendingSoftSkips: [SoftSkipRecord] {
        get {
            preferences.data(forKey: Self.pendingSoftSkipsKey)
                .flatMap { try? JSONDecoder().decode([SoftSkipRecord].self, from: $0) } ?? []
        }
        set {
            if newValue.isEmpty { preferences.removeObject(forKey: Self.pendingSoftSkipsKey) }
            else { preferences.set(try? JSONEncoder().encode(newValue), forKey: Self.pendingSoftSkipsKey) }
        }
    }

    /// Records the Skip, then offers Undo. The audio is reclaimed when the offer ends without being
    /// taken (it ran out, or was withdrawn); if no offer can be made, at once.
    func offerSoftSkipUndo(_ record: SoftSkipRecord, rows: [WiltedMacEpisode], changed: Int) {
        let feedIDs = Set(rows.compactMap(\.feedID))
        pendingSoftSkips.append(record)
        let offered = undoToast.offer(
            message: "Skipped \(changed) episode\(changed == 1 ? "" : "s")",
            actionName: "Skip", subjects: Set(record.retiredIDs.map(\.rawValue)),
            onClose: { [weak self] in self?.closeSoftSkip(record, feedIDs: feedIDs) },
            undo: { [weak self] in self?.undoSoftSkip(record, rows: rows) ?? .done }
        )
        if offered == nil { closeSoftSkip(record, feedIDs: feedIDs) }
    }

    /// Runs the undo through the Feed writer, so it commits in order with every other decision.
    /// Something still saving on one of these rows keeps the offer open instead of spending it.
    private func undoSoftSkip(_ record: SoftSkipRecord, rows: [WiltedMacEpisode]) -> WiltedMacUndoResult {
        guard !isClosingTemporaryState else { return .done }
        guard pendingFeedDecisionIDs.isDisjoint(with: rows.map(\.id)) else { return .retry }
        decideFeedEpisodes(.undoSkip(record), episodes: rows)
        return .done
    }

    /// The offer ended: reclaim the audio, in order after every decision already queued.
    private func closeSoftSkip(_ record: SoftSkipRecord, feedIDs: Set<String>) {
        enqueueFeedWriteAfterDecisions { [weak self] in
            await self?.finishSoftSkip(record, feedIDs: feedIDs)
        }
    }

    /// Reclaims the audio of every member still retired from this Skip, withdraws their waiting
    /// preparation, and lets the feed's next waiting episode into the slot they free. A failure keeps
    /// the record, so the next launch tries again.
    func finishSoftSkip(_ record: SoftSkipRecord, feedIDs: Set<String>) async {
        guard let store, !isClosingTemporaryState else { return }
        do {
            let stillRetired = try await store.finalizeSoftSkip(record.retiredIDs, at: record.retiredAt)
            pendingSoftSkips.removeAll { $0 == record }
            guard !isClosingTemporaryState else { return }
            for id in stillRetired { withdrawPreparationRequest(for: id.rawValue) }
            if !stillRetired.isEmpty { await releaseWaitingEpisodes(feedIDs: feedIDs) }
        } catch {
            podcastOperationMessage = "Skipped audio could not be cleared; it will be tried again."
        }
    }

    /// Closes every Skip an earlier launch left open. No offer exists any more, so none can be taken back.
    func closeAbandonedSoftSkips(in store: LocalLibraryStore) async {
        for record in pendingSoftSkips {
            if (try? await store.finalizeSoftSkip(record.retiredIDs, at: record.retiredAt)) != nil {
                pendingSoftSkips.removeAll { $0 == record }
            }
        }
    }

    /// Takes back a soft Skip in the store and reloads what shows it. The undo changes only members
    /// whose decision is still this Skip's own; a newer action on any member is left as it stands.
    func commitUndoSoftSkip(_ record: SoftSkipRecord, rows: [WiltedMacEpisode], store: LocalLibraryStore) async throws -> Set<String> {
        let restored = Set(try await store.undoSoftSkip(record).map(\.rawValue))
        if !restored.isEmpty {
            libraryReadEpoch &+= 1
            lastAppliedLibraryReadEpoch = libraryReadEpoch
            podcastQueueRefreshGeneration &+= 1
        }
        await feedDecisionAfterDurableCommitForTesting?()
        guard !isClosingTemporaryState, !Task.isCancelled else { return restored }
        await refreshPodcastQueueState()
        guard !isClosingTemporaryState, !Task.isCancelled else { return restored }
        await reloadLibraryRows()
        // A member the undo could not restore (changed since) is still retired from this Skip: close it.
        await finishSoftSkip(record, feedIDs: Set(rows.compactMap(\.feedID)))
        return restored
    }

    /// Queues one write behind every Feed decision already admitted, without marking rows pending.
    func enqueueFeedWriteAfterDecisions(_ body: @escaping @MainActor () async -> Void) {
        guard !isClosingTemporaryState else { return }
        let token = UUID()
        let predecessor = feedDecisionWriteTailToken.flatMap { subscriptionWriteTasks[$0] }
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.subscriptionWriteTasks[token] = nil
                    if self.feedDecisionWriteTailToken == token { self.feedDecisionWriteTailToken = nil }
                }
            }
            if let predecessor { await predecessor.value }
            guard let self, !self.isClosingTemporaryState, !Task.isCancelled else { return }
            await body()
        }
        subscriptionWriteTasks[token] = task
        feedDecisionWriteTailToken = token
    }
}
#endif
